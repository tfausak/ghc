%
% (c) The University of Glasgow, 1994-2000
%
\section{Core pass to saturate constructors and PrimOps}

\begin{code}
module CorePrep (
      corePrepPgm, corePrepExpr
  ) where

#include "HsVersions.h"

import CoreUtils( exprIsAtom, exprType, exprIsValue, etaExpand, exprArity, exprOkForSpeculation )
import CoreFVs	( exprFreeVars )
import CoreLint	( endPass )
import CoreSyn
import Type	( Type, applyTy, splitFunTy_maybe, isTyVarTy,
		  isUnLiftedType, isUnboxedTupleType, repType,	
		  uaUTy, usOnce, usMany, eqUsage, seqType )
import NewDemand  ( Demand, isStrictDmd, lazyDmd, StrictSig(..), DmdType(..) )
import PrimOp	( PrimOp(..) )
import Var 	( Var, Id, setVarUnique )
import VarSet
import VarEnv
import Id	( mkSysLocal, idType, idNewDemandInfo, idArity,
		  setIdType, isPrimOpId_maybe, isFCallId, isLocalId, 
		  hasNoBinding, idNewStrictness
		)
import HscTypes ( ModDetails(..) )
import UniqSupply
import Maybes
import OrdList
import ErrUtils
import CmdLineOpts
import Outputable
\end{code}

-- ---------------------------------------------------------------------------
-- Overview
-- ---------------------------------------------------------------------------

The goal of this pass is to prepare for code generation.

1.  Saturate constructor and primop applications.

2.  Convert to A-normal form:

    * Use case for strict arguments:
	f E ==> case E of x -> f x
    	(where f is strict)

    * Use let for non-trivial lazy arguments
	f E ==> let x = E in f x
	(were f is lazy and x is non-trivial)

3.  Similarly, convert any unboxed lets into cases.
    [I'm experimenting with leaving 'ok-for-speculation' 
     rhss in let-form right up to this point.]

4.  Ensure that lambdas only occur as the RHS of a binding
    (The code generator can't deal with anything else.)

5.  Do the seq/par munging.  See notes with mkCase below.

6.  Clone all local Ids.  This means that Tidy Core has the property
    that all Ids are unique, rather than the weaker guarantee of
    no clashes which the simplifier provides.

7.  Give each dynamic CCall occurrence a fresh unique; this is
    rather like the cloning step above.

This is all done modulo type applications and abstractions, so that
when type erasure is done for conversion to STG, we don't end up with
any trivial or useless bindings.

  


-- -----------------------------------------------------------------------------
-- Top level stuff
-- -----------------------------------------------------------------------------

\begin{code}
corePrepPgm :: DynFlags -> ModDetails -> IO ModDetails
corePrepPgm dflags mod_details
  = do	showPass dflags "CorePrep"
	us <- mkSplitUniqSupply 's'
	let new_binds = initUs_ us (corePrepTopBinds emptyVarEnv (md_binds mod_details))
        endPass dflags "CorePrep" Opt_D_dump_sat new_binds
	return (mod_details { md_binds = new_binds })

corePrepExpr :: DynFlags -> CoreExpr -> IO CoreExpr
corePrepExpr dflags expr
  = do showPass dflags "CorePrep"
       us <- mkSplitUniqSupply 's'
       let new_expr = initUs_ us (corePrepAnExpr emptyVarEnv expr)
       dumpIfSet_dyn dflags Opt_D_dump_sat "CorePrep" 
		     (ppr new_expr)
       return new_expr

-- ---------------------------------------------------------------------------
-- Dealing with bindings
-- ---------------------------------------------------------------------------

data FloatingBind = FloatLet CoreBind
		  | FloatCase Id CoreExpr Bool
			-- The bool indicates "ok-for-speculation"

instance Outputable FloatingBind where
  ppr (FloatLet bind)        = text "FloatLet" <+> ppr bind
  ppr (FloatCase b rhs spec) = text "FloatCase" <+> ppr b <+> ppr spec <+> equals <+> ppr rhs

type CloneEnv = IdEnv Id	-- Clone local Ids

allLazy :: OrdList FloatingBind -> Bool
allLazy floats 
  = foldrOL check True floats
  where
    check (FloatLet _)  	      y = y
    check (FloatCase _ _ ok_for_spec) y = ok_for_spec && y
	-- The ok-for-speculation flag says that it's safe to
	-- float this Case out of a let, and thereby do it more eagerly
	-- We need the top-level flag because it's never ok to float
	-- an unboxed binding to the top level

-- ---------------------------------------------------------------------------
-- 			Bindings
-- ---------------------------------------------------------------------------

corePrepTopBinds :: CloneEnv -> [CoreBind] -> UniqSM [CoreBind]
corePrepTopBinds env [] = returnUs []

corePrepTopBinds env (bind : binds)
  = corePrepTopBind env bind		`thenUs` \ (env', bind') ->
    corePrepTopBinds env' binds		`thenUs` \ binds' ->
    returnUs (bind' : binds')

-- From top level bindings we don't get any floats
-- (a) it isn't necessary because the mkAtomicArgs in Simplify
--	has already done all the floating necessary
-- (b) floating would give rise to top-level LocaIds, generated
-- 	by CorePrep.newVar.  That breaks the invariant that
--	after CorePrep all top-level vars are GlobalIds

corePrepTopBind :: CloneEnv -> CoreBind -> UniqSM (CloneEnv, CoreBind)
corePrepTopBind env (NonRec bndr rhs) 
  = corePrepRhs env (bndr, rhs)		`thenUs` \ rhs' ->
    cloneBndr env bndr			`thenUs` \ (env', bndr') ->
    returnUs (env', NonRec bndr' rhs')

corePrepTopBind env (Rec pairs)
  = corePrepRecPairs env pairs		`thenUs` \ (env', pairs') ->
    returnUs (env, Rec pairs')

corePrepRecPairs env pairs
  = cloneBndrs env bndrs		`thenUs` \ (env', bndrs') ->
    mapUs (corePrepRhs env') pairs	`thenUs` \ rhss' ->
    returnUs (env', bndrs' `zip` rhss')
  where
    bndrs = map fst pairs

corePrepRhs :: CloneEnv -> (Id, CoreExpr) -> UniqSM CoreExpr
corePrepRhs env (bndr, rhs)
-- Prepare the RHS and eta expand it. 
-- No nonsense about floating
  = corePrepAnExpr env rhs	`thenUs` \ rhs' ->
    getUniquesUs		`thenUs` \ us ->
    returnUs (etaExpand (exprArity rhs') us rhs' (idType bndr))


corePrepBind ::  CloneEnv -> CoreBind -> UniqSM (CloneEnv, OrdList FloatingBind)
-- This one is used for *local* bindings
-- We return a *list* of bindings, because we may start with
--	x* = f (g y)
-- where x is demanded, in which case we want to finish with
--	a = g y
--	x* = f a
-- And then x will actually end up case-bound

corePrepBind env (NonRec bndr rhs)
  = corePrepExprFloat env rhs				`thenUs` \ (floats, rhs') ->
    cloneBndr env bndr					`thenUs` \ (env', bndr') ->
    mkLocalNonRec bndr' (bdrDem bndr') floats rhs'	`thenUs` \ floats' ->
    returnUs (env', floats')

corePrepBind env (Rec pairs)
	-- Don't bother to try to float bindings out of RHSs
	-- (compare mkNonRec, which does try)
  = corePrepRecPairs env pairs			`thenUs` \ (env', pairs') ->
    returnUs (env', unitOL (FloatLet (Rec pairs')))

-- ---------------------------------------------------------------------------
-- Making arguments atomic (function args & constructor args)
-- ---------------------------------------------------------------------------

-- This is where we arrange that a non-trivial argument is let-bound
corePrepArg :: CloneEnv -> CoreArg -> RhsDemand
	   -> UniqSM (OrdList FloatingBind, CoreArg)
corePrepArg env arg dem
  = corePrepExprFloat env arg		`thenUs` \ (floats, arg') ->
    if needs_binding arg'
	then returnUs (floats, arg')
	else newVar (exprType arg')		`thenUs` \ v ->
	     mkLocalNonRec v dem floats arg'	`thenUs` \ floats' -> 
	     returnUs (floats', Var v)

needs_binding | opt_RuntimeTypes = exprIsAtom
	      | otherwise	 = exprIsTrivial

-- version that doesn't consider an scc annotation to be trivial.
exprIsTrivial (Var v)
  | hasNoBinding v		       = idArity v == 0
  | otherwise                          = True
exprIsTrivial (Type _)	      	       = True
exprIsTrivial (Lit lit)       	       = True
exprIsTrivial (App e arg)     	       = isTypeArg arg && exprIsTrivial e
exprIsTrivial (Note (SCC _) e) 	       = False
exprIsTrivial (Note _ e)      	       = exprIsTrivial e
exprIsTrivial (Lam b body) | isTyVar b = exprIsTrivial body
exprIsTrivial other	      	       = False

-- ---------------------------------------------------------------------------
-- Dealing with expressions
-- ---------------------------------------------------------------------------

corePrepAnExpr :: CloneEnv -> CoreExpr -> UniqSM CoreExpr
corePrepAnExpr env expr
  = corePrepExprFloat env expr		`thenUs` \ (floats, expr) ->
    mkBinds floats expr


corePrepExprFloat :: CloneEnv -> CoreExpr -> UniqSM (OrdList FloatingBind, CoreExpr)
-- If
--	e  ===>  (bs, e')
-- then	
--	e = let bs in e'	(semantically, that is!)
--
-- For example
--	f (g x)	  ===>   ([v = g x], f v)

corePrepExprFloat env (Var v)
  = fiddleCCall v				`thenUs` \ v1 ->
    let v2 = lookupVarEnv env v1 `orElse` v1 in
    maybeSaturate v2 (Var v2) 0 (idType v2) 	`thenUs` \ app ->
    returnUs (nilOL, app)

corePrepExprFloat env expr@(Type _)
  = returnUs (nilOL, expr)

corePrepExprFloat env expr@(Lit lit)
  = returnUs (nilOL, expr)

corePrepExprFloat env (Let bind body)
  = corePrepBind env bind		`thenUs` \ (env', new_binds) ->
    corePrepExprFloat env' body		`thenUs` \ (floats, new_body) ->
    returnUs (new_binds `appOL` floats, new_body)

corePrepExprFloat env (Note n@(SCC _) expr)
  = corePrepAnExpr env expr		`thenUs` \ expr1 ->
    deLam expr1				`thenUs` \ expr2 ->
    returnUs (nilOL, Note n expr2)

corePrepExprFloat env (Note other_note expr)
  = corePrepExprFloat env expr		`thenUs` \ (floats, expr') ->
    returnUs (floats, Note other_note expr')

corePrepExprFloat env expr@(Lam _ _)
  = corePrepAnExpr env body		`thenUs` \ body' ->
    returnUs (nilOL, mkLams bndrs body')
  where
    (bndrs,body) = collectBinders expr

corePrepExprFloat env (Case scrut bndr alts)
  = corePrepExprFloat env scrut		`thenUs` \ (floats, scrut') ->
    cloneBndr env bndr			`thenUs` \ (env', bndr') ->
    mapUs (sat_alt env') alts		`thenUs` \ alts' ->
    returnUs (floats, mkCase scrut' bndr' alts')
  where
    sat_alt env (con, bs, rhs)
	  = cloneBndrs env bs		`thenUs` \ (env', bs') ->
	    corePrepAnExpr env' rhs  	`thenUs` \ rhs1 ->
	    deLam rhs1			`thenUs` \ rhs2 ->
	    returnUs (con, bs', rhs2)

corePrepExprFloat env expr@(App _ _)
  = collect_args expr 0  `thenUs` \ (app, (head,depth), ty, floats, ss) ->
    ASSERT(null ss)	-- make sure we used all the strictness info

	-- Now deal with the function
    case head of
      Var fn_id -> maybeSaturate fn_id app depth ty `thenUs` \ app' -> 
	    	   returnUs (floats, app')

      _other    -> returnUs (floats, app)

  where

    -- Deconstruct and rebuild the application, floating any non-atomic
    -- arguments to the outside.  We collect the type of the expression,
    -- the head of the application, and the number of actual value arguments,
    -- all of which are used to possibly saturate this application if it
    -- has a constructor or primop at the head.

    collect_args
	:: CoreExpr
	-> Int				  -- current app depth
	-> UniqSM (CoreExpr,		  -- the rebuilt expression
		   (CoreExpr,Int),	  -- the head of the application,
				          -- and no. of args it was applied to
		   Type,		  -- type of the whole expr
		   OrdList FloatingBind,  -- any floats we pulled out
		   [Demand])		  -- remaining argument demands

    collect_args (App fun arg@(Type arg_ty)) depth
        = collect_args fun depth   `thenUs` \ (fun',hd,fun_ty,floats,ss) ->
	  returnUs (App fun' arg, hd, applyTy fun_ty arg_ty, floats, ss)

    collect_args (App fun arg) depth
        = collect_args fun (depth+1)   `thenUs` \ (fun',hd,fun_ty,floats,ss) ->
	  let
	      (ss1, ss_rest)   = case ss of
				   (ss1:ss_rest) -> (ss1,     ss_rest)
				   []	         -> (lazyDmd, [])
              (arg_ty, res_ty) = expectJust "corePrepExprFloat:collect_args" $
                                 splitFunTy_maybe fun_ty
	  in
	  corePrepArg env arg (mkDemTy ss1 arg_ty)	`thenUs` \ (fs, arg') ->
	  returnUs (App fun' arg', hd, res_ty, fs `appOL` floats, ss_rest)

    collect_args (Var v) depth
	= fiddleCCall v `thenUs` \ v1 ->
	  let v2 = lookupVarEnv env v1 `orElse` v1 in
	  returnUs (Var v2, (Var v2, depth), idType v2, nilOL, stricts)
	where
	  stricts = case idNewStrictness v of
			StrictSig (DmdType _ demands _)
			    | depth >= length demands -> demands
			    | otherwise               -> []
		-- If depth < length demands, then we have too few args to 
		-- satisfy strictness  info so we have to  ignore all the 
		-- strictness info, e.g. + (error "urk")
		-- Here, we can't evaluate the arg strictly, because this 
		-- partial application might be seq'd


    collect_args (Note (Coerce ty1 ty2) fun) depth
        = collect_args fun depth  `thenUs` \ (fun', hd, fun_ty, floats, ss) ->
	  returnUs (Note (Coerce ty1 ty2) fun', hd, ty1, floats, ss)

    collect_args (Note note fun) depth
	| ignore_note note 
        = collect_args fun depth   `thenUs` \ (fun', hd, fun_ty, floats, ss) ->
	  returnUs (Note note fun', hd, fun_ty, floats, ss)

	-- non-variable fun, better let-bind it
    collect_args fun depth
	= corePrepExprFloat env fun			`thenUs` \ (fun_floats, fun) ->
	  newVar ty			 		`thenUs` \ fn_id ->
          mkLocalNonRec fn_id onceDem fun_floats fun	`thenUs` \ floats ->
	  returnUs (Var fn_id, (Var fn_id, depth), ty, floats, [])
        where
	  ty = exprType fun

    ignore_note	InlineCall = True
    ignore_note	InlineMe   = True
    ignore_note	_other     = False
	-- we don't ignore SCCs, since they require some code generation

------------------------------------------------------------------------------
-- Building the saturated syntax
-- ---------------------------------------------------------------------------

-- maybeSaturate deals with saturating primops and constructors
-- The type is the type of the entire application
maybeSaturate :: Id -> CoreExpr -> Int -> Type -> UniqSM CoreExpr
maybeSaturate fn expr n_args ty
  | hasNoBinding fn = saturate_it
  | otherwise       = returnUs expr
  where
    fn_arity	 = idArity fn
    excess_arity = fn_arity - n_args
    saturate_it  = getUniquesUs 		`thenUs` \ us ->
		   returnUs (etaExpand excess_arity us expr ty)

-- ---------------------------------------------------------------------------
-- Precipitating the floating bindings
-- ---------------------------------------------------------------------------

-- mkLocalNonRec is used only for local bindings
mkLocalNonRec :: Id  -> RhsDemand 			-- Lhs: id with demand
	      -> OrdList FloatingBind -> CoreExpr	-- Rhs: let binds in body
	      -> UniqSM (OrdList FloatingBind)

mkLocalNonRec bndr dem floats rhs
  | exprIsValue rhs && allLazy floats 		-- Notably constructor applications
  = 	-- Why the test for allLazy? You might think that the only 
	-- floats we can get out of a value are eta expansions 
	-- e.g.  C $wJust ==> let s = \x -> $wJust x in C s
	-- Here we want to float the s binding.
	--
	-- But if the programmer writes this:
	--	f x = case x of { (a,b) -> \y -> a }
	-- then the strictness analyser may say that f has strictness "S"
	-- Later the eta expander will transform to
	--	f x y = case x of { (a,b) -> a }
	-- So now f has arity 2.  Now CorePrep may see
	--	v = f E
	-- so the E argument will turn into a FloatCase.  
	-- Indeed we should end up with
	--	v = case E of { r -> f r }
	-- That is, we should not float, even though (f r) is a value
	--
	-- Similarly, given 
	--	v = f (x `divInt#` y)
	-- we don't want to float the case, even if f has arity 2,
	-- because floating the case would make it evaluated too early
	--
	-- Finally, eta-expand the RHS, for the benefit of the code gen
	-- NB: we could refrain when the RHS is trivial (which can happen
	--     for exported things.  This would reduce the amount of code
	--     generated (a little) and make things a little words for
	--     code compiled without -O.  The case in point is data constructor
	--     wrappers.
	--
    getUniquesUs		`thenUs` \ us ->
    let
	rhs' = etaExpand (exprArity rhs) us rhs bndr_ty
    in
    returnUs (floats `snocOL` FloatLet (NonRec bndr rhs'))
    
  |  isUnLiftedType bndr_rep_ty	|| isStrict dem 
	-- It's a strict let, or the binder is unlifted,
	-- so we definitely float all the bindings
  = ASSERT( not (isUnboxedTupleType bndr_rep_ty) )
    returnUs (floats `snocOL` FloatCase bndr rhs (exprOkForSpeculation rhs))

  | otherwise
	-- Don't float; the RHS isn't a value
  = mkBinds floats rhs	`thenUs` \ rhs' ->
    returnUs (unitOL (FloatLet (NonRec bndr rhs')))

  where
    bndr_ty	 = idType bndr
    bndr_rep_ty  = repType bndr_ty

mkBinds :: OrdList FloatingBind -> CoreExpr -> UniqSM CoreExpr
mkBinds binds body 
  | isNilOL binds = returnUs body
  | otherwise	  = deLam body		`thenUs` \ body' ->
		    returnUs (foldrOL mk_bind body' binds)
  where
    mk_bind (FloatCase bndr rhs _) body = mkCase rhs bndr [(DEFAULT, [], body)]
    mk_bind (FloatLet bind)        body = Let bind body

-- ---------------------------------------------------------------------------
-- Eliminate Lam as a non-rhs (STG doesn't have such a thing)
-- We arrange that they only show up as the RHS of a let(rec)
-- ---------------------------------------------------------------------------

deLam :: CoreExpr -> UniqSM CoreExpr	
-- Remove top level lambdas by let-bindinig

deLam (Note n expr)
  =	-- You can get things like
	-- 	case e of { p -> coerce t (\s -> ...) }
    deLam expr	`thenUs` \ expr' ->
    returnUs (Note n expr')

deLam expr 
  | null bndrs = returnUs expr
  | otherwise  = case tryEta bndrs body of
		   Just no_lam_result -> returnUs no_lam_result
		   Nothing	      -> newVar (exprType expr) `thenUs` \ fn ->
					 returnUs (Let (NonRec fn expr) (Var fn))
  where
    (bndrs,body) = collectBinders expr

-- Why try eta reduction?  Hasn't the simplifier already done eta?
-- But the simplifier only eta reduces if that leaves something
-- trivial (like f, or f Int).  But for deLam it would be enough to
-- get to a partial application, like (map f).

tryEta bndrs expr@(App _ _)
  | ok_to_eta_reduce f &&
    n_remaining >= 0 &&
    and (zipWith ok bndrs last_args) &&
    not (any (`elemVarSet` fvs_remaining) bndrs)
  = Just remaining_expr
  where
    (f, args) = collectArgs expr
    remaining_expr = mkApps f remaining_args
    fvs_remaining = exprFreeVars remaining_expr
    (remaining_args, last_args) = splitAt n_remaining args
    n_remaining = length args - length bndrs

    ok bndr (Var arg) = bndr == arg
    ok bndr other	    = False

	  -- we can't eta reduce something which must be saturated.
    ok_to_eta_reduce (Var f) = not (hasNoBinding f)
    ok_to_eta_reduce _       = False --safe. ToDo: generalise

tryEta bndrs (Let bind@(NonRec b r) body)
  | not (any (`elemVarSet` fvs) bndrs)
  = case tryEta bndrs body of
	Just e -> Just (Let bind e)
	Nothing -> Nothing
  where
    fvs = exprFreeVars r

tryEta bndrs _ = Nothing
\end{code}


-- -----------------------------------------------------------------------------
-- 	Do the seq and par transformation
-- -----------------------------------------------------------------------------

Here we do two pre-codegen transformations:

1.	case seq# a of {
	  0 	  -> seqError ...
	  DEFAULT -> rhs }
  ==>
	case a of { DEFAULT -> rhs }


2.	case par# a of {
	  0 	  -> parError ...
	  DEFAULT -> rhs }
  ==>
	case par# a of {
	  DEFAULT -> rhs }

NB:	seq# :: a -> Int#	-- Evaluate value and return anything
	par# :: a -> Int#	-- Spark value and return anything

These transformations can't be done earlier, or else we might
think that the expression was strict in the variables in which 
rhs is strict --- but that would defeat the purpose of seq and par.


\begin{code}
mkCase scrut@(Var fn `App` Type ty `App` arg) bndr alts@(deflt_alt@(DEFAULT,_,rhs) : con_alts)
			-- DEFAULT alt is always first
  = case isPrimOpId_maybe fn of
	Just ParOp -> Case scrut bndr     [deflt_alt]
	Just SeqOp -> Case arg   new_bndr [deflt_alt]
	other	   -> Case scrut bndr alts
  where
	-- The binder shouldn't be used in the expression!
    new_bndr = ASSERT2( not (bndr `elemVarSet` exprFreeVars rhs), ppr bndr )
	       setIdType bndr (exprType arg)
	-- NB:  SeqOp :: forall a. a -> Int#
	-- So bndr has type Int# 
	-- But now we are going to scrutinise the SeqOp's argument directly,
	-- so we must change the type of the case binder to match that
	-- of the argument expression e.

mkCase scrut bndr alts = Case scrut bndr alts
\end{code}


-- -----------------------------------------------------------------------------
-- Demands
-- -----------------------------------------------------------------------------

\begin{code}
data RhsDemand
     = RhsDemand { isStrict :: Bool,  -- True => used at least once
                   isOnceDem   :: Bool   -- True => used at most once
                 }

mkDem :: Demand -> Bool -> RhsDemand
mkDem strict once = RhsDemand (isStrictDmd strict) once

mkDemTy :: Demand -> Type -> RhsDemand
mkDemTy strict ty = RhsDemand (isStrictDmd strict) (isOnceTy ty)

isOnceTy :: Type -> Bool
isOnceTy ty
  =
#ifdef USMANY
    opt_UsageSPOn &&  -- can't expect annotations if -fusagesp is off
#endif
    once
  where
    u = uaUTy ty
    once | u `eqUsage` usOnce  = True
         | u `eqUsage` usMany  = False
         | isTyVarTy u 	       = False  -- if unknown at compile-time, is Top ie usMany

bdrDem :: Id -> RhsDemand
bdrDem id = mkDem (idNewDemandInfo id) (isOnceTy (idType id))

safeDem, onceDem :: RhsDemand
safeDem = RhsDemand False False  -- always safe to use this
onceDem = RhsDemand False True   -- used at most once
\end{code}




%************************************************************************
%*									*
\subsection{Cloning}
%*									*
%************************************************************************

\begin{code}
------------------------------------------------------------------------------
-- Cloning binders
-- ---------------------------------------------------------------------------

cloneBndrs :: CloneEnv -> [Var] -> UniqSM (CloneEnv, [Var])
cloneBndrs env bs = mapAccumLUs cloneBndr env bs

cloneBndr  :: CloneEnv -> Var -> UniqSM (CloneEnv, Var)
cloneBndr env bndr
  | isId bndr && isLocalId bndr		-- Top level things, which we don't want
					-- to clone, have become GlobalIds by now
  = getUniqueUs   `thenUs` \ uniq ->
    let
	bndr' = setVarUnique bndr uniq
    in
    returnUs (extendVarEnv env bndr bndr', bndr')

  | otherwise = returnUs (env, bndr)

------------------------------------------------------------------------------
-- Cloning ccall Ids; each must have a unique name,
-- to give the code generator a handle to hang it on
-- ---------------------------------------------------------------------------

fiddleCCall :: Id -> UniqSM Id
fiddleCCall id 
  | isFCallId id = getUniqueUs   	`thenUs` \ uniq ->
		   returnUs (id `setVarUnique` uniq)
  | otherwise    = returnUs id

------------------------------------------------------------------------------
-- Generating new binders
-- ---------------------------------------------------------------------------

newVar :: Type -> UniqSM Id
newVar ty
 = getUniqueUs	 		`thenUs` \ uniq ->
   seqType ty			`seq`
   returnUs (mkSysLocal SLIT("sat") uniq ty)
\end{code}
