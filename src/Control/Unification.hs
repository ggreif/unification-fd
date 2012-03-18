{-# LANGUAGE MultiParamTypeClasses, FlexibleContexts #-}
{-# OPTIONS_GHC -Wall -fwarn-tabs -fno-warn-name-shadowing #-}
----------------------------------------------------------------
--                                                  ~ 2012.03.16
-- |
-- Module      :  Control.Unification
-- Copyright   :  Copyright (c) 2007--2012 wren ng thornton
-- License     :  BSD
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  experimental
-- Portability :  semi-portable (MPTCs, FlexibleContexts)
--
-- This module provides first-order structural unification over
-- general structure types. It also provides the standard suite of
-- functions accompanying unification (applying bindings, getting
-- free variables, etc.).
--
-- The implementation makes use of numerous optimization techniques.
-- First, we use path compression everywhere (for weighted path
-- compression see "Control.Unification.Ranked"). Second, we replace
-- the occurs-check with visited-sets. Third, we use a technique
-- for aggressive opportunistic observable sharing; that is, we
-- track as much sharing as possible in the bindings (without
-- introducing new variables), so that we can compare bound variables
-- directly and therefore eliminate redundant unifications.
----------------------------------------------------------------
module Control.Unification
    (
    -- * Data types, classes, etc
    -- ** Mutable terms
      MutTerm(..)
    , freeze
    , unfreeze
    -- ** Errors
    , UnificationFailure(..)
    -- ** Basic type classes
    , Unifiable(..)
    , Variable(..)
    , BindingMonad(..)
    
    -- * Operations on one term
    , getFreeVars
    , applyBindings
    , freshen
    -- freezeM     -- apply bindings and freeze in one traversal
    -- unskolemize -- convert Skolemized variables to free variables
    -- skolemize   -- convert free variables to Skolemized variables
    -- getSkolems  -- compute the skolem variables in a term; helpful?
    
    -- * Operations on two terms
    -- ** Symbolic names
    , (===)
    , (=~=)
    , (=:=)
    , (<:=)
    -- ** Textual names
    , equals
    , equiv
    , unify
    , unifyOccurs
    , subsumes
    
    -- * Operations on many terms
    , getFreeVarsAll
    -- applyBindingsAll -- necessary to ensure sharing across multiple terms
    , freshenAll
    -- subsumesAll -- to ensure that there's a single coherent substitution allowing the schema to subsume all the terms in some collection. 

    -- * Helper functions
    -- | Client code should not need to use these functions, but
    -- they are exposed just in case they are needed.
    , fullprune
    , semiprune
    , occursIn
    -- TODO: add a post-hoc occurs check in order to have a version of unify which is fast, yet is also guaranteed to fail when it out to (rather than deferring the failure until later, as the current unify does).
    ) where

import Prelude
    hiding (mapM, mapM_, sequence, foldr, foldr1, foldl, foldl1, all, and, or)

import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import Data.Foldable
import Data.Traversable
import Control.Monad.Identity (Identity(..))
import Control.Applicative
import Control.Monad       (MonadPlus(..))
import Control.Monad.Trans (MonadTrans(..))
import Control.Monad.Error (MonadError(..))
import Control.Monad.State (MonadState(..), StateT, evalStateT, execStateT)
import Control.Monad.MaybeK
import Control.Monad.State.UnificationExtras
import Control.Unification.Types
----------------------------------------------------------------
----------------------------------------------------------------

-- N.B., this assumes there are no directly-cyclic chains!
--
-- | Canonicalize a chain of variables so they all point directly
-- to the term at the end of the chain (or the free variable, if
-- the chain is unbound), and return that end.
--
-- N.B., this is almost never the function you want. Cf., 'semiprune'.
fullprune :: (BindingMonad t v m) => MutTerm t v -> m (MutTerm t v)
fullprune t0@(MutTerm _ ) = return t0
fullprune t0@(MutVar  v0) = do
    mb <- lookupVar v0
    case mb of
        Nothing -> return t0
        Just t  -> do
            finalTerm <- fullprune t
            v0 `bindVar` finalTerm
            return finalTerm


-- N.B., this assumes there are no directly-cyclic chains!
--
-- | Canonicalize a chain of variables so they all point directly
-- to the last variable in the chain, regardless of whether it is
-- bound or not. This allows detecting many cases where multiple
-- variables point to the same term, thereby allowing us to avoid
-- re-unifying the term they point to.
semiprune :: (BindingMonad t v m) => MutTerm t v -> m (MutTerm t v)
semiprune t0@(MutTerm _ ) = return t0
semiprune t0@(MutVar  v0) = loop t0 v0
    where
    -- We pass the @t@ for @v@ in order to add just a little more sharing.
    loop t0 v0 = do
        mb <- lookupVar v0
        case mb of
            Nothing -> return t0
            Just t  -> 
                case t  of
                MutTerm _  -> return t0
                MutVar  v  -> do
                    finalVar <- loop t v
                    v0 `bindVar` finalVar
                    return finalVar


-- | Determine if a variable appears free somewhere inside a term.
-- Since occurs checks only make sense when we're about to bind the
-- variable to the term, we do not bother checking for the possibility
-- of the variable occuring bound in the term.
occursIn :: (BindingMonad t v m) => v -> MutTerm t v -> m Bool
{-# INLINE occursIn #-}
occursIn v0 t0 = do
    t0 <- fullprune t0
    case t0 of
        MutTerm t -> or <$> mapM (v0 `occursIn`) t
            -- TODO: benchmark the following for shortcircuiting
            -- > Traversable.foldlM (\b t' -> if b then return True else v0 `occursIn` t') t
        MutVar  v -> return $! v0 `eqVar` v


-- TODO: use IM.insertWith or the like to do this in one pass
-- | Update the visited-set with a seclaration that a variable has
-- been seen with a given binding, or throw 'OccursIn' if the
-- variable has already been seen.
seenAs
    ::  ( BindingMonad t v m
        , MonadTrans e
        , MonadError (UnificationFailure t v) (e m)
        )
    => v -- ^
    -> MutTerm t v -- ^
    -> StateT (IM.IntMap (MutTerm t v)) (e m) () -- ^
{-# INLINE seenAs #-}
seenAs v0 t0 = do
    seenVars <- get
    case IM.lookup (getVarID v0) seenVars of
        Just t  -> lift . throwError $ OccursIn v0 t
        Nothing -> put $! IM.insert (getVarID v0) t0 seenVars

----------------------------------------------------------------
----------------------------------------------------------------

-- TODO: these assume pure variables, hence the spine cloning; but
-- we may want to make variants for impure variables with explicit
-- rollback on backtracking.

-- TODO: See if MTL still has that overhead over doing things manually.

-- TODO: Figure out how to abstract the left-catamorphism from these.


-- | Walk a term and determine which variables are still free. N.B.,
-- this function does not detect cyclic terms (i.e., throw errors),
-- but it will return the correct answer for them in finite time.
getFreeVars :: (BindingMonad t v m) => MutTerm t v -> m [v]
getFreeVars = getFreeVarsAll . Identity

-- TODO: Should we return the IntMap instead?
--
-- | Walk a collection of terms and determine which variables are
-- still free. This is the same as 'getFreeVars', but somewhat more
-- efficient if you have multiple terms to traverse at once.
getFreeVarsAll
    :: (BindingMonad t v m, Foldable s)
    => s (MutTerm t v) -> m [v]
getFreeVarsAll ts0 =
    IM.elems <$> evalStateT (loopAll ts0) IS.empty
    where
    -- TODO: is that the most efficient way?
    loopAll = foldrM (\t r -> IM.union r <$> loop t) IM.empty
    
    loop t0 = do
        t0 <- lift $ semiprune t0
        case t0 of
            MutTerm t -> fold <$> mapM loop t -- TODO: use foldlM instead?
            MutVar  v -> do
                seenVars <- get
                let i = getVarID v
                if IS.member i seenVars
                    then return IM.empty -- no (more) free vars down here
                    else do
                        put $! IS.insert i seenVars
                        mb <- lift $ lookupVar v
                        case mb of
                            Just t' -> loop t'
                            Nothing -> return $ IM.singleton i v


-- | Apply the current bindings from the monad so that any remaining
-- variables in the result must, therefore, be free. N.B., this
-- expensively clones term structure and should only be performed
-- when a pure term is needed, or when 'OccursIn' exceptions must
-- be forced. This function /does/ preserve sharing, however that
-- sharing is no longer observed by the monad.
--
-- If any cyclic bindings are detected, then an 'OccursIn' exception
-- will be thrown.
applyBindings
    ::  ( BindingMonad t v m
        , MonadTrans e
        , Functor (e m) -- Grr, Monad(e m) should imply Functor(e m)
        , MonadError (UnificationFailure t v) (e m)
        )
    => MutTerm t v       -- ^
    -> e m (MutTerm t v) -- ^
applyBindings t0 = evalStateT (loop t0) IM.empty
    where
    loop t0 = do
        t0 <- lift . lift $ semiprune t0
        case t0 of
            MutTerm t -> MutTerm <$> mapM loop t
            MutVar  v -> do
                let i = getVarID v
                mb <- IM.lookup i <$> get
                case mb of
                    Just (Right t) -> return t
                    Just (Left  t) -> lift . throwError $ OccursIn v t
                    Nothing -> do
                        mb' <- lift . lift $ lookupVar v
                        case mb' of
                            Nothing -> return t0
                            Just t  -> do
                                modify' . IM.insert i $ Left t
                                t' <- loop t
                                modify' . IM.insert i $ Right t'
                                return t'


-- | Freshen all variables in a term, both bound and free. This
-- ensures that the observability of sharing is maintained, while
-- freshening the free variables. N.B., this expensively clones
-- term structure and should only be performed when necessary.
--
-- If any cyclic bindings are detected, then an 'OccursIn' exception
-- will be thrown.
freshen
    ::  ( BindingMonad t v m
        , MonadTrans e
        , Functor (e m) -- Grr, Monad(e m) should imply Functor(e m)
        , MonadError (UnificationFailure t v) (e m)
        )
    => MutTerm t v       -- ^
    -> e m (MutTerm t v) -- ^
freshen = fmap runIdentity . freshenAll . Identity


-- | Same as 'freshen', but works on several terms simultaneously.
-- This is different from 'freshen'ing each term separately, because
-- 'freshenAll' preserves the relationship between the terms. For
-- instance, the result of
--
-- > mapM freshen [Var 1, Var 1]
--
-- could be @[Var 2, Var 3]@, while the result of
--
-- > freshenAll [Var 1, Var 1]
--
-- must be @[Var 2, Var 2]@ or something alpha-equivalent.
freshenAll
    ::  ( BindingMonad t v m
        , MonadTrans e
        , Functor (e m) -- Grr, Monad(e m) should imply Functor(e m)
        , MonadError (UnificationFailure t v) (e m)
        , Traversable s
        )
    => s (MutTerm t v)       -- ^
    -> e m (s (MutTerm t v)) -- ^
freshenAll ts0 = evalStateT (mapM loop ts0) IM.empty
    where
    loop t0 = do
        t0 <- lift . lift $ semiprune t0
        case t0 of
            MutTerm t -> MutTerm <$> mapM loop t
            MutVar  v -> do
                let i = getVarID v
                seenVars <- get
                case IM.lookup i seenVars of
                    Just (Right t) -> return t
                    Just (Left  t) -> lift . throwError $ OccursIn v t
                    Nothing -> do
                        mb <- lift . lift $ lookupVar v
                        case mb of
                            Nothing -> do
                                v' <- lift . lift $ MutVar <$> freeVar
                                put $! IM.insert i (Right v') seenVars
                                return v'
                            Just t  -> do
                                put $! IM.insert i (Left t) seenVars
                                t' <- loop t
                                v' <- lift . lift $ MutVar <$> newVar t'
                                modify' $ IM.insert i (Right v')
                                return v'

----------------------------------------------------------------
----------------------------------------------------------------
-- BUG: have to give the signatures for Haddock :(

-- | 'equals'
(===)
    :: (BindingMonad t v m)
    => MutTerm t v  -- ^
    -> MutTerm t v  -- ^
    -> m Bool       -- ^
(===) = equals
{-# INLINE (===) #-}
infix 4 ===, `equals`


-- | 'equiv'
(=~=)
    :: (BindingMonad t v m)
    => MutTerm t v               -- ^
    -> MutTerm t v               -- ^
    -> m (Maybe (IM.IntMap Int)) -- ^
(=~=) = equiv
{-# INLINE (=~=) #-}
infix 4 =~=, `equiv`


-- | 'unify'
(=:=)
    ::  ( BindingMonad t v m
        , MonadTrans e
        , Functor (e m) -- Grr, Monad(e m) should imply Functor(e m)
        , MonadError (UnificationFailure t v) (e m)
        )
    => MutTerm t v       -- ^
    -> MutTerm t v       -- ^
    -> e m (MutTerm t v) -- ^
(=:=) = unify
{-# INLINE (=:=) #-}
infix 4 =:=, `unify`


-- | 'subsumes'
(<:=)
    ::  ( BindingMonad t v m
        , MonadTrans e
        , Functor (e m) -- Grr, Monad(e m) should imply Functor(e m)
        , MonadError (UnificationFailure t v) (e m)
        )
    => MutTerm t v -- ^
    -> MutTerm t v -- ^
    -> e m Bool
(<:=) = subsumes
{-# INLINE (<:=) #-}
infix 4 <:=, `subsumes`

----------------------------------------------------------------

{- BUG:
If we don't use anything special, then there's a 2x overhead for
calling 'equals' (and probably the rest of them too). If we add a
SPECIALIZE pragma, or if we try to use MaybeT instead of MaybeKT
then that jumps up to 4x overhead. However, if we add an INLINE
pragma then it gets faster than the same implementation in the
benchmark file. I've no idea what's going on here...
-}

-- TODO: should we offer a variant which gives the reason for failure?
--
-- | Determine if two terms are structurally equal. This is essentially
-- equivalent to @('==')@ except that it does not require applying
-- bindings before comparing, so it is more efficient. N.B., this
-- function does not consider alpha-variance, and thus variables
-- with different names are considered unequal. Cf., 'equiv'.
equals
    :: (BindingMonad t v m)
    => MutTerm t v  -- ^
    -> MutTerm t v  -- ^
    -> m Bool       -- ^
equals tl0 tr0 = do
    mb <- runMaybeKT (loop tl0 tr0)
    case mb of
        Nothing -> return False
        Just () -> return True
    where
    loop tl0 tr0 = do
        tl0 <- lift $ semiprune tl0
        tr0 <- lift $ semiprune tr0
        case (tl0, tr0) of
            (MutVar vl, MutVar vr)
                | vl `eqVar` vr -> return () -- success
                | otherwise     -> do
                    mtl <- lift $ lookupVar vl
                    mtr <- lift $ lookupVar vr
                    case (mtl, mtr) of
                        (Nothing, Nothing ) -> mzero
                        (Nothing, Just _  ) -> mzero
                        (Just _,  Nothing ) -> mzero
                        (Just tl, Just tr) -> loop tl tr -- TODO: should just jump to match
            (MutVar  _,  MutTerm _  ) -> mzero
            (MutTerm _,  MutVar  _  ) -> mzero
            (MutTerm tl, MutTerm tr) ->
                case zipMatch tl tr of
                Nothing  -> mzero
                Just tlr -> mapM_ (uncurry loop) tlr


-- TODO: is that the most helpful return type?
--
-- | Determine if two terms are structurally equivalent; that is,
-- structurally equal modulo renaming of free variables. Returns a
-- mapping from variable IDs of the left term to variable IDs of
-- the right term, indicating the renaming used.
equiv
    :: (BindingMonad t v m)
    => MutTerm t v               -- ^
    -> MutTerm t v               -- ^
    -> m (Maybe (IM.IntMap Int)) -- ^
equiv tl0 tr0 = runMaybeKT (execStateT (loop tl0 tr0) IM.empty)
    where
    loop tl0 tr0 = do
        tl0 <- lift . lift $ fullprune tl0
        tr0 <- lift . lift $ fullprune tr0
        case (tl0, tr0) of
            (MutVar vl,  MutVar  vr) -> do
                let il = getVarID vl
                let ir = getVarID vr
                xs <- get
                case IM.lookup il xs of
                    Just x
                        | x == ir   -> return ()
                        | otherwise -> lift mzero
                    Nothing         -> put $! IM.insert il ir xs
            
            (MutVar  _,  MutTerm _ ) -> lift mzero
            (MutTerm _,  MutVar  _ ) -> lift mzero
            (MutTerm tl, MutTerm tr) ->
                case zipMatch tl tr of
                Nothing  -> lift mzero
                Just tlr -> mapM_ (uncurry loop) tlr


----------------------------------------------------------------
-- Not quite unify2 from the benchmarks, since we do AOOS.
--
-- | A variant of 'unify' which uses 'occursIn' instead of visited-sets.
-- This should only be used when eager throwing of 'OccursIn' errors
-- is absolutely essential (or for testing the correctness of
-- @unify@). Performing the occurs-check is expensive. Not only is
-- it slow, it's asymptotically slow since it can cause the same
-- subterm to be traversed multiple times.
unifyOccurs
    ::  ( BindingMonad t v m
        , MonadTrans e
        , Functor (e m) -- Grr, Monad(e m) should imply Functor(e m)
        , MonadError (UnificationFailure t v) (e m)
        )
    => MutTerm t v       -- ^
    -> MutTerm t v       -- ^
    -> e m (MutTerm t v) -- ^
unifyOccurs = loop
    where
    {-# INLINE (=:) #-}
    v =: t = lift $ v `bindVar` t
    
    {-# INLINE acyclicBindVar #-}
    acyclicBindVar v t = do
        b <- lift $ v `occursIn` t
        if b
            then throwError $ OccursIn v t
            else v =: t
    
    -- TODO: cf todos in 'unify'
    loop tl0 tr0 = do
        tl0 <- lift $ semiprune tl0
        tr0 <- lift $ semiprune tr0
        case (tl0, tr0) of
            (MutVar vl, MutVar vr)
                | vl `eqVar` vr -> return tr0
                | otherwise     -> do
                    mtl <- lift $ lookupVar vl
                    mtr <- lift $ lookupVar vr
                    case (mtl, mtr) of
                        (Nothing,  Nothing ) -> do
                            vl =: tr0
                            return tr0
                        (Nothing,  Just _  ) -> do
                            vl `acyclicBindVar` tr0
                            return tr0
                        (Just _  , Nothing ) -> do
                            vr `acyclicBindVar` tl0
                            return tl0
                        (Just tl, Just tr) -> do
                            t <- loop tl tr
                            vr =: t
                            vl =: tr0
                            return tr0
            
            (MutVar vl, MutTerm _) -> do
                mtl <- lift $ lookupVar vl
                case mtl of
                    Nothing  -> do
                        vl `acyclicBindVar` tr0
                        return tl0
                    Just tl -> do
                        t <- loop tl tr0
                        vl =: t
                        return tl0
            
            (MutTerm _, MutVar vr) -> do
                mtr <- lift $ lookupVar vr
                case mtr of
                    Nothing  -> do
                        vr `acyclicBindVar` tl0
                        return tr0
                    Just tr -> do
                        t <- loop tl0 tr
                        vr =: t
                        return tr0
            
            (MutTerm tl, MutTerm tr) ->
                case zipMatch tl tr of
                Nothing  -> throwError $ TermMismatch tl tr
                Just tlr -> MutTerm <$> mapM (uncurry loop) tlr


----------------------------------------------------------------
-- TODO: verify correctness, especially for the visited-set stuff.
-- TODO: return Maybe(MutTerm t v) in the loop so we can avoid updating bindings trivially
-- TODO: figure out why unifyOccurs is so much faster on pure ground terms!! The only difference there is in lifting over StateT...
-- 
-- | Unify two terms, or throw an error with an explanation of why
-- unification failed. Since bindings are stored in the monad, the
-- two input terms and the output term are all equivalent if
-- unification succeeds. However, the returned value makes use of
-- aggressive opportunistic observable sharing, so it will be more
-- efficient to use it in future calculations than either argument.
unify
    ::  ( BindingMonad t v m
        , MonadTrans e
        , Functor (e m) -- Grr, Monad(e m) should imply Functor(e m)
        , MonadError (UnificationFailure t v) (e m)
        )
    => MutTerm t v       -- ^
    -> MutTerm t v       -- ^
    -> e m (MutTerm t v) -- ^
unify tl0 tr0 = evalStateT (loop tl0 tr0) IM.empty
    where
    {-# INLINE (=:) #-}
    v =: t = lift . lift $ v `bindVar` t
    
    -- TODO: would it be beneficial to manually fuse @x <- lift m; y <- lift n@ to @(x,y) <- lift (m;n)@ everywhere we can?
    loop tl0 tr0 = do
        tl0 <- lift . lift $ semiprune tl0
        tr0 <- lift . lift $ semiprune tr0
        case (tl0, tr0) of
            (MutVar vl, MutVar vr)
                | vl `eqVar` vr -> return tr0
                | otherwise     -> do
                    mtl <- lift . lift $ lookupVar vl
                    mtr <- lift . lift $ lookupVar vr
                    case (mtl, mtr) of
                        (Nothing, Nothing) -> do vl =: tr0 ; return tr0
                        (Nothing, Just _ ) -> do vl =: tr0 ; return tr0
                        (Just _ , Nothing) -> do vr =: tl0 ; return tl0
                        (Just tl, Just tr) -> do
                            t <- localState $ do
                                vl `seenAs` tl
                                vr `seenAs` tr
                                loop tl tr -- TODO: should just jump to match
                            vr =: t
                            vl =: tr0
                            return tr0
            
            (MutVar vl, MutTerm _) -> do
                t <- do
                    mtl <- lift . lift $ lookupVar vl
                    case mtl of
                        Nothing  -> return tr0
                        Just tl -> localState $ do
                            vl `seenAs` tl
                            loop tl tr0 -- TODO: should just jump to match
                vl =: t
                return tl0
            
            (MutTerm _, MutVar vr) -> do
                t <- do
                    mtr <- lift . lift $ lookupVar vr
                    case mtr of
                        Nothing  -> return tl0
                        Just tr -> localState $ do
                            vr `seenAs` tr
                            loop tl0 tr -- TODO: should just jump to match
                vr =: t
                return tr0
            
            (MutTerm tl, MutTerm tr) ->
                case zipMatch tl tr of
                Nothing  -> lift . throwError $ TermMismatch tl tr
                Just tlr -> MutTerm <$> mapM (uncurry loop) tlr

----------------------------------------------------------------
-- TODO: can we find an efficient way to return the bindings directly instead of altering the monadic bindings? Maybe another StateT IntMap taking getVarID to the variable and its pseudo-bound term?
--
-- TODO: verify correctness
-- TODO: redo with some codensity
-- TODO: there should be some way to catch OccursIn errors and repair the bindings...

-- | Determine whether the left term subsumes the right term. That
-- is, whereas @(tl =:= tr)@ will compute the most general substitution
-- @s@ such that @(s tl === s tr)@, @(tl <:= tr)@ computes the most
-- general substitution @s@ such that @(s tl === tr)@. This means
-- that @tl@ is less defined than and consistent with @tr@.
--
-- /N.B./, this function updates the monadic bindings just like
-- 'unify' does. However, while the use cases for unification often
-- want to keep the bindings around, the use cases for subsumption
-- usually do not. Thus, you'll probably want to use a binding monad
-- which supports backtracking in order to undo the changes.
-- Unfortunately, leaving the monadic bindings unaltered and returning
-- the necessary substitution directly imposes a performance penalty
-- or else requires specifying too much about the implementation
-- of variables.
subsumes
    ::  ( BindingMonad t v m
        , MonadTrans e
        , Functor (e m) -- Grr, Monad(e m) should imply Functor(e m)
        , MonadError (UnificationFailure t v) (e m)
        )
    => MutTerm t v -- ^
    -> MutTerm t v -- ^
    -> e m Bool    -- ^
subsumes tl0 tr0 = evalStateT (loop tl0 tr0) IM.empty
    where
    {-# INLINE (=:) #-}
    v =: t = lift . lift $ do v `bindVar` t ; return True
    
    -- TODO: cf todos in 'unify'
    loop tl0 tr0 = do
        tl0 <- lift . lift $ semiprune tl0
        tr0 <- lift . lift $ semiprune tr0
        case (tl0, tr0) of
            (MutVar vl, MutVar vr)
                | vl `eqVar` vr -> return True
                | otherwise     -> do
                    mtl <- lift . lift $ lookupVar vl
                    mtr <- lift . lift $ lookupVar vr
                    case (mtl, mtr) of
                        (Nothing, Nothing) -> vl =: tr0
                        (Nothing, Just _ ) -> vl =: tr0
                        (Just _ , Nothing) -> return False
                        (Just tl, Just tr) ->
                            localState $ do
                                vl `seenAs` tl
                                vr `seenAs` tr
                                loop tl tr
            
            (MutVar vl,  MutTerm _ ) -> do
                mtl <- lift . lift $ lookupVar vl
                case mtl of
                    Nothing  -> vl =: tr0
                    Just tl -> localState $ do
                        vl `seenAs` tl
                        loop tl tr0
            
            (MutTerm _,  MutVar  _ ) -> return False
            
            (MutTerm tl, MutTerm tr) ->
                case zipMatch tl tr of
                Nothing  -> return False
                Just tlr -> and <$> mapM (uncurry loop) tlr
                    -- TODO: use foldlM?
    

----------------------------------------------------------------
----------------------------------------------------------- fin.
