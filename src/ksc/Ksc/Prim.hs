-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT license.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}

module Ksc.Prim where

import Ksc.Lang
import Ksc.LangUtils (isTrivial)
import GHC.Stack (HasCallStack)
import Data.Maybe (isJust)
import Control.Monad (zipWithM)
import Text.PrettyPrint (($$), (<+>), text, vcat)

--------------------------------------------
--  Simple call construction
--------------------------------------------

primCall :: PrimFun -> Type -> TExpr -> TExpr
primCall fun res_ty arg
  = Call (TFun res_ty (Fun JustFun (BaseFunId (BasePrimFunName fun) arg_ty))) arg
  where arg_ty = typeof arg

userCall :: String -> Type -> TExpr -> TExpr
userCall fun res_ty arg
  = Call (TFun res_ty (Fun JustFun (BaseFunId (BaseUserFunName fun) arg_ty))) arg
  where arg_ty = typeof arg

mkPrimCall :: HasCallStack => PrimFun -> TExpr -> TExpr
mkPrimCall fun args
  = primCall fun res_ty args
  where
    res_ty = primFunCallResultTy fun args

mkPrimCall1 :: HasCallStack => PrimFun -> TExpr -> TExpr
mkPrimCall1 f a = mkPrimCall f a

mkPrimCall2 :: HasCallStack => PrimFun -> TExpr -> TExpr -> TExpr
mkPrimCall2 f a b = mkPrimCall f (Tuple [a, b])

mkPrimCall3 :: HasCallStack => PrimFun -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall3 f a b c = mkPrimCall f (Tuple [a, b, c])

mkPrimCall4 :: HasCallStack => PrimFun -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall4 f a b c d = mkPrimCall f (Tuple [a, b, c, d])

mkPrimCall5 :: HasCallStack => PrimFun -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall5 f a b c d e = mkPrimCall f (Tuple [a, b, c, d, e])

mkPrimCall6 :: HasCallStack => PrimFun -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall6 f a b c d e g = mkPrimCall f (Tuple [a, b, c, d, e, g])

mkPrimCall7 :: HasCallStack => PrimFun -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall7 f a b c d e g h = mkPrimCall f (Tuple [a, b, c, d, e, g, h])

---------------------------
-- Zeros
---------------------------
mkZero, mkTangentZero :: HasCallStack => TExpr -> TExpr
mkZero        = getZero id
mkTangentZero = getZero tangentType

getZero :: HasCallStack => (Type -> Type) -> TExpr -> TExpr
getZero tangent_type e
  = go e
  where
    go e = case tangent_type e_ty of
            TypeInteger  -> Konst (KInteger 0)
            TypeFloat    -> Konst (KFloat 0.0)
            TypeString   -> Konst (KString "")
            TypeBool     -> Konst (KBool False)
            TypeTensor d _ -> mkAtomicNoFVs e $ \ e ->
                            pConstVec (pSize e) (go (pIndex (zeroIndexForDimension d) e))
            TypeTuple ts
               | Tuple es <- e
               -> assert (text "splitTuple") (length ts == length es) $
                  Tuple (map go  es)
               | let n = length ts
               -> mkAtomicNoFVs e $ \e ->
                  Tuple $ map go $
                  [ pSel i n e | i <- [1..n] ]
            TypeLam _ _ -> panic
            TypeLM _ _ -> panic
            TypeUnknown -> panic
         where
           e_ty = typeof e
           panic = pprPanic "mkZero" (ppr e_ty $$ ppr e)

data MakeShapeOrTrivial = TrivialShapeWithTZ TExpr
                        -- ^ The shape can be determined solely from
                        -- the type (and so we choose it to be unit).
                        -- Its tangent zero is this TExpr.
                        | NonTrivialShape MakeShape

data MakeShape = MakeShape { msMakeShape :: TExpr -> TExpr
                           , msShapeType :: Type
                           , msMakeTZ    :: TExpr -> TExpr
                           }

shape :: TExpr -> Maybe TExpr
shape e = do
  ms <- makeShape (typeof e)
  pure (msMakeShape ms e)

shape1 :: TExpr -> Maybe TExpr
shape1 e = do
  ms <- makeShape1 (typeof e)
  pure (msMakeShape ms e)

shapeType :: Type -> Maybe Type
shapeType = fmap msShapeType . makeShape

makeTangentZeroFromShape :: Type -> Maybe (TExpr -> TExpr)
makeTangentZeroFromShape = fmap msMakeTZ . makeShape

makeShape :: Type -> Maybe MakeShape
makeShape = fmap unTrivial . makeShapeOrTrivial

makeShape1 :: Type -> Maybe MakeShape
makeShape1 = fmap unTrivial . makeShapeOrTrivial1

unTrivial :: MakeShapeOrTrivial -> MakeShape
unTrivial = \case
  TrivialShapeWithTZ zero -> MakeShape { msMakeShape = const (Tuple [])
                                       , msShapeType = TypeTuple []
                                       , msMakeTZ    = const zero
                                       }
  NonTrivialShape mktz -> mktz

makeShapeOrTrivial :: Type -> Maybe MakeShapeOrTrivial
makeShapeOrTrivial = makeShapeOrTrivialG makeShapeOrTrivial

makeShapeOrTrivial1 :: Type -> Maybe MakeShapeOrTrivial
makeShapeOrTrivial1 = makeShapeOrTrivialG (\t -> flip fmap (makeShapeOrTrivial1 t) $ \case
  NonTrivialShape m -> NonTrivialShape m{ msMakeShape = pShape }
  t@TrivialShapeWithTZ{} -> t)

{- Note [Shapes]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Introduction
------------

Some types T have an associated (compressed) shape type st(T).

If T has a shape type then values x : T have a corresponding shape
value sv(x) : st(T).

The type of some shapes is "trivial".  This means that the shape of x
does not depend on the value of x, i.e. all values of the type have
the same shape.  In such cases we choose unit tuple type as the shape
type and unit tuple as the shape (see unTrivial).

For "non-trivial" shapes the value of sv(x) depends on x.

Given the shape of x : T we can make the tangent zero of shape x (of
type dT).  This is for use in reverse mode AD transformations.


Table of shape transformations
------------------------------


T               |           st T         |         sv x
----------------------------------------------------------------------------
Float           |                        |
Integer         |                        |
Bool            |                        |
String          |          ()            |         ()
                |                        |
(T1, T2)        |                        |
(both trivial)  |   (called "trivial")   |
                |                        |
----------------------------------------------------------------------------
(T1, T2)        |                        |
(not both       |    (cst T1, cst T2)    |  let (fresh1, fresh2) = x
 trivial)       |                        |  in (sv fresh1, sv fresh2)
----------------------------------------------------------------------------
                |                        |
Vec T           |        Integer         |       size x
(T trivial)     |                        |
----------------------------------------------------------------------------
                |                        |
Vec T           |      Vec (cst T)       |       map sv x
(T not trivial) |                        |
----------------------------------------------------------------------------


shape vs shape1
---------------

shape is csv applied recursively to the base types, e.g. for
x : (Vec Float, Float)

    shape x = let (fresh1, fresh2) = x
              in (size fresh1, ())

On the other hand shape1 is csv applied only one level, e.g.

    shape1 x = let (fresh1, fresh2) = x
               in (P_shape fresh1, P_shape fresh2)

(P_shape is the call to the primitive function "shape")

It is important to use shape1 instead of shape in
Ksc.Opt.Shape.optShape to give the optimiser the opportunity to apply
Ksc.Opt.Shape.optShapePrim.


Uncompressed shapes
-------------------

The codebase also contains an older implementation of uncompressed
shape types which we intend to replace with compressed shape types.
See Note [Uncompressed shapes]

-}

makeShapeOrTrivialG :: (Type -> Maybe MakeShapeOrTrivial)
                    -> Type -> Maybe MakeShapeOrTrivial
makeShapeOrTrivialG recurse = \case
  -- Trivial shapes
  --
  -- The type of some shapes is "trivial".  This means that the shape
  -- of x does not depend on the value of x, i.e. all values of the
  -- type have the same shape.  In such cases we choose unit tuple
  -- type as the shape type and unit tuple as the shape (see
  -- unTrivial).
  TypeInteger -> Just (TrivialShapeWithTZ unit)
  TypeFloat   -> Just (TrivialShapeWithTZ zeroFloat)
  TypeBool    -> Just (TrivialShapeWithTZ unit)
  TypeString  -> Just (TrivialShapeWithTZ unit)

  -- Tuple shapes
  --
  -- For a tuple value t : T = (C_1, ..., C_N)
  --
  -- * If the shape type of each C_i is trivial then the shape type of
  --   T is trivial
  --
  -- * Otherwise the shape type is the tuple of shape types of the
  --   components, i.e. (shapeType C_1, ..., shapeType C_n), and the
  --   shape is
  --
  --       let (fresh_1, ..., fresh_n) = t in (shape fresh_1, ..., shape fresh_n)
  --
  --   (where 'shape' is determined by the call to 'recurse')
  TypeTuple ts -> case tangentZerosForAllTrivialShapeMaybe ts of
    Just tangentZeros -> Just (TrivialShapeWithTZ (Tuple tangentZeros))
    Nothing  -> case mapM (\t -> do {m <- recurse t; pure (t, m)}) ts of
      Nothing    -> Nothing
      Just ts_ms -> Just $ NonTrivialShape MakeShape{ msMakeShape = makeShape'
                                                    , msShapeType = shapeType'
                                                    , msMakeTZ = makeTZ' }
        where rts = map f (zip ts_ms [1..])
              f ((t, m), i) = (v, z, mktz)
                where v = TVar t (mkArgVar i)
                      mktz = unTrivial m
                      z = TVar (msShapeType mktz) (mkArgVar i)

              ss = map (\(v, _, _) -> v) rts
              shape_body = Tuple (map (\(v, _, mktz) -> msMakeShape mktz (Var v)) rts)
              makeShape' e = Let (TupPat ss) e shape_body

              shapeType' = TypeTuple (map (\(_, _, mktz) -> msShapeType mktz) rts)

              zs = map (\(_, z, _) -> z) rts
              makeTZ_body = Tuple (map (\(_, z, mktz) -> msMakeTZ mktz (Var z)) rts)
              makeTZ' e = Let (TupPat zs) e makeTZ_body

    where tangentZerosForAllTrivialShapeMaybe :: [Type] -> Maybe [TExpr]
          tangentZerosForAllTrivialShapeMaybe =
            mapM (\t -> recurse t >>= \case
                          TrivialShapeWithTZ tangentZero -> Just tangentZero
                          NonTrivialShape _ -> Nothing)

  -- Tensor shapes
  --
  -- For a tensor value t : T = Tensor n E
  --
  -- * If the shape type of E is trivial then the shape type of T is
  --   index type of Tensor n and the shape is the size of the tensor.
  --
  -- * Otherwise the shape type is Tensor n (shapeType E) and the
  --   shape value is
  --
  --       map (\v -> shape v) t
  --
  --   (where 'shape' is determined by the call to 'recurse')
  TypeTensor i t -> fmap NonTrivialShape $ flip fmap (recurse t) $ \case
    TrivialShapeWithTZ zero -> MakeShape{ msMakeShape = pSize
                                        , msShapeType = tensorIndexType i
                                        , msMakeTZ    = \n -> pConstVec n zero }
    NonTrivialShape mktz ->
      MakeShape{ msMakeShape = eMap t (msMakeShape mktz)
               , msShapeType = TypeTensor i elt_ty
               , msMakeTZ    = eMap elt_ty (msMakeTZ mktz)
               }
      where eMap :: Type -> (TExpr -> TExpr) -> TExpr -> TExpr
            eMap ty shape = mkPrimCall2 P_map (Lam v (shape (Var v)))
              where v = TVar ty argVar
            elt_ty = msShapeType mktz

  TypeLam{} -> Nothing
  TypeLM{} -> Nothing
  TypeUnknown -> Nothing
  where unit = Tuple []

-- (mkAtomicNoFVs e body) returns the expression (let a = e in body a)
-- where body :: TExpr -> TExpr is a function expecting an expression
-- The idea is that body might use its argument many types, and we
-- don't want to duplicate e, so we let-bind it instead
--
-- NB1: there's a short-cut when e is trivial (e.g. another variable)
--
-- NB2: we use the same variable name every time.  That's not safe in
--      general, but the bodys we use never mention any other variables,
--      so it's fine c.f. the more general Opt.makeAtomic, which does
--      not have this side condition but which requires an in-scope
--      set
mkAtomicNoFVs :: TExpr -> (TExpr -> TExpr) -> TExpr
mkAtomicNoFVs e body
  | isTrivial e = body e
  | otherwise   = mkLet ev e (body (Var ev))
  where
    ev = TVar (typeof e) argVar

--------------------------------------------
--  Building simple calls
--------------------------------------------

{-  Note [Shapes]
~~~~~~~~~~~~~~~~~
When doing AD we have the 'S' parameter, which we need to build a zero
linear map.  We make it a named type, Shape, because it could be
implemented in various ways.

- Shape = Type     This worked when we had vector sizes in types

- Shape = Expr     The value tuple of function argumetnts

- Shape = Expr     A new value abstracting the shape of the function
                   arguments (e.g. an Int for a vector, describing its
                   size)

Note [lmZero]
~~~~~~~~~~~~~
lmZero should have type  lmZero :: forall s t. s -o t
When applied, via `lmApply` or `lmApplyR`, it should produce
a zero value of type T(t) or T(s) respectively.  Alas, that
is tricky to do, given only the types.  How can we produce a
zero of type (Vec Float) for example?  How big should it be?

Our solution is to pass a /value/ of type s, and one of type t,
to lmZero, and provide mkTangentZero to turn that value into a
zero value.  Painful, but possible.
-}

type Shape = TExpr

lmZero :: Shape -> Shape -> TExpr
lmZero s t = mkPrimCall1 P_lmZero (Tuple [s, t])

-- lmOne S :: S -o S
lmOne :: Type -> TExpr
lmOne s = mkPrimCall1 P_lmOne (mkDummy s)

-- lmScale S :: Float -> (S -o S)
-- lmApply (lmScale S r) s = ts_scale r s
lmScale :: HasCallStack => Type -> TExpr -> TExpr
lmScale s r = mkPrimCall1 P_lmScale (Tuple [mkDummy s, r])

-- lmScaleR :: S -> (Float -o S)
-- lmScaleR S :: Float -o S
-- lmApply (lmScaleR S) r = ts_scale r s
lmScaleR :: HasCallStack => TExpr -> TExpr
lmScaleR v = mkPrimCall1 P_lmScaleR v

-- lmDot :: S -> (S -o Float)
-- lmDot s :: S -o Float
-- lmApply (lmDot s) s' = ts_dot (s,s')
lmDot :: HasCallStack => TExpr -> TExpr
lmDot s = mkPrimCall1 P_lmDot s

lmAdd :: HasCallStack => TExpr -> TExpr -> TExpr
lmAdd = mkPrimCall2 P_lmAdd

lmAdds :: HasCallStack => [TExpr]-> TExpr
lmAdds [] = error "lmAdds of empty list (perhaps this should return lmZero?)"
lmAdds [x] = x
lmAdds (x:xs) = lmAdd x (lmAdds xs)

lmHCat :: HasCallStack => [TExpr] -> TExpr
lmHCat [e] = e
lmHCat es  = mkPrimCall P_lmHCat (Tuple es)

lmHCatV :: HasCallStack => TExpr -> TExpr
lmHCatV e  = mkPrimCall1 P_lmHCatV e

-- The argument tuple to ksc's primitive function lmVCat must have two
-- or more components.  The Haskell function Prim.lmVCat therefore
-- checks whether the argument list is empty.  If it is then lmZero is
-- a suitable replacement.  It doesn't check if the argument list has
-- length one.  Such a call may fail later in the pipeline.  See also
-- Prim.primFunCallResultTy_maybe.
lmVCat :: HasCallStack => TExpr -> [TExpr] -> TExpr
lmVCat s []  = lmZero s (Tuple [])
lmVCat _ es  = mkPrimCall1 P_lmVCat (Tuple es)

lmVCatV :: HasCallStack => TExpr -> TExpr
lmVCatV e  = mkPrimCall1 P_lmVCatV e

lmCompose :: TExpr -> TExpr -> TExpr
lmCompose = mkPrimCall2 P_lmCompose

lmApply :: HasCallStack => TExpr -> TExpr -> TExpr
lmApply = mkPrimCall2 P_lmApply

lmApplyR :: HasCallStack => TExpr -> TExpr -> TExpr
lmApplyR = mkPrimCall2 P_lmApplyR

lmApply_Dir :: HasCallStack => ADDir -> TExpr -> TExpr -> TExpr
lmApply_Dir Fwd e ds = lmApply  e ds
lmApply_Dir Rev e dt = lmApplyR dt e

lmBuildT :: HasCallStack => TExpr -> TExpr -> TExpr
lmBuildT n b = lmHCatV (pBuild n b)

lmFold :: HasCallStack => TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
lmFold = mkPrimCall5 P_lmFold

pFFold :: HasCallStack => TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
pFFold = mkPrimCall6 P_FFold

pRFold :: HasCallStack => Type -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
pRFold = mkPrimCall7 P_RFold . mkDummy

isThePrimFun :: TFun p -> PrimFun -> Bool
isThePrimFun (TFun _ (Fun JustFun (PrimFunT f1))) f2 = f1 == f2
isThePrimFun _ _ = False

isLMOne :: TExpr -> Bool
isLMOne (Call f _) = f `isThePrimFun` P_lmOne
isLMOne _ = False

isLMZero :: TExpr -> Bool
isLMZero = isJust . isLMZero_maybe

isLMZero_maybe :: TExpr -> Maybe (TExpr, TExpr)
-- Just (a,b) means that the input was indeed (lmZero (a,b))
isLMZero_maybe (Call f args)
  | f `isThePrimFun` P_lmZero
  , (Tuple [a,b]) <- args
  = Just (a,b)
isLMZero_maybe _ = Nothing

isKZero :: TExpr -> Bool
isKZero = \case
  Konst (KInteger 0  ) -> True
  Konst (KFloat   0.0) -> True
  Tuple ts -> all isKZero ts
  Call f (Tuple [_,v]) | f `isThePrimFun` P_constVec -> isKZero v
  _ -> False

isBuild_maybe :: TExpr -> Maybe (TExpr, TVar, TExpr)
isBuild_maybe (Call f (Tuple [n,Lam i e]))
  | f `isThePrimFun` P_build
  = Just (n, i, e)
isBuild_maybe _ = Nothing

isConstVec_maybe :: TExpr -> Maybe (TExpr, TExpr)
isConstVec_maybe (Call f (Tuple [n, v]))
  | f `isThePrimFun` P_constVec
  = Just (n, v)
isConstVec_maybe _ = Nothing

lmDelta :: TExpr -> TExpr -> TExpr -> TExpr
lmDelta t i j = If (pEqual i j) (lmOne ty) (lmZero t t)
  where
    ty = typeof t

isEqualityCall :: TExpr -> Maybe (TExpr, TExpr)
isEqualityCall (Call f (Tuple [e1,e2]))
  | f `isThePrimFun` P_eq = Just (e1,e2)
isEqualityCall _          = Nothing

-----------------------
-- Delta and diag

pDelta :: TExpr -> TExpr -> TExpr -> TExpr
-- delta i j e  =  if i==j then e else zero
pDelta i j e = mkPrimCall1 P_delta (Tuple [i, j, e])

pDeltaVec :: TExpr -> TExpr -> TExpr -> TExpr
-- deltaVec size i e = build size (\j. delta i j e)
-- Returns a size-vector with e at index i, and zeros elsewhere
pDeltaVec sz i e = mkPrimCall1 P_deltaVec (Tuple [sz, i, e])

pConstVec :: TExpr -> TExpr -> TExpr
-- constVec size e = build size (\_. e)
pConstVec = mkPrimCall2 P_constVec

pDiag :: TExpr -> TExpr -> TExpr -> TExpr
-- diag rows cols (\i. e) = build row (\i. deltaVec cols i e)
pDiag = mkPrimCall3 P_diag

---------------------------
-- "User-defined" functions
---------------------------
pAdd, pEqual, pScale, pDot :: HasCallStack => TExpr -> TExpr -> TExpr
pAdd   = mkPrimCall2 P_ts_add
pEqual = mkPrimCall2 P_eq
pScale = mkPrimCall2 P_ts_scale
pDot   = mkPrimCall2 P_ts_dot

pAdd1 :: TExpr -> TExpr
pAdd1 = mkPrimCall1 P_ts_add

pBuild :: TExpr -> TExpr -> TExpr
pBuild = mkPrimCall2 P_build

pIndex :: TExpr -> TExpr -> TExpr
pIndex = mkPrimCall2 P_index

pSum :: TExpr -> TExpr
pSum = mkPrimCall1 P_sum

pSumBuild :: TExpr -> TExpr -> TExpr
pSumBuild = mkPrimCall2 P_sumbuild

pUnzip :: TExpr -> TExpr
pUnzip = mkPrimCall1 P_unzip

pShape :: TExpr -> TExpr
pShape = mkPrimCall1 P_shape

pSize :: TExpr -> TExpr
pSize e = mkPrimCall1 P_size e

pToFloat :: TExpr -> TExpr
pToFloat from = userCall "to_float" TypeFloat from

pMulii :: TExpr -> TExpr -> TExpr
pMulii x1 x2 = userCall "mul" TypeInteger (Tuple [x1, x2])

pMulff :: TExpr -> TExpr -> TExpr
pMulff x1 x2 = userCall "mul" TypeFloat (Tuple [x1, x2])

pDup :: Int -> TExpr -> TExpr
pDup n = mkPrimCall1 (P_dup n)

pElim :: TExpr -> TExpr
pElim = mkPrimCall1 P_elim

pInline :: TExpr -> TExpr
pInline = mkPrimCall1 P_inline

---------------------------------------------
--       Types of primitive functions
--
--  For each primitve, we give its type
--  And this is the /only/ place we do this
---------------------------------------------

primCallResultTy_maybe :: HasCallStack => DerivedFun PrimFun Typed -> Type
                       -> Either SDoc Type
primCallResultTy_maybe fun arg_ty
  = case fun of
      Fun JustFun (BaseFunId f _)
         | Just ty <- primFunCallResultTy_maybe f arg_ty
         -> Right ty
         | otherwise
         -> Left (text "Ill-typed call to primitive:" <+> ppr fun)

      Fun GradFun f
        -> case primCallResultTy_maybe (Fun JustFun f) arg_ty of
            Left err -> Left err
            Right res_ty -> Right (mkGradType arg_ty res_ty)

      Fun (DrvFun adm) f
        | Fwd <- adm    -- f :: S1 -> T, then fwd$f :: (S1, S2_t) -> T_t
        , TypeTuple [x, _dx] <- arg_ty
        , Right t_ty <- primCallResultTy_maybe (Fun JustFun f) x
        -> Right (tangentType t_ty)

        | Rev <- adm    -- f :: S1 -> T, then rev$f :: (S1, T_t) -> S1_t
        , TypeTuple [s, _dt] <- arg_ty
        -> Right (tangentType s)
        | otherwise
        -> Left (text "Ill-typed call to:" <+> ppr fun)
      
      Fun (ShapeFun ds) f
        -> case primCallResultTy_maybe (Fun ds f) arg_ty of
            Left err -> Left err
            Right res_ty -> case shapeType res_ty of
              Just t -> Right t
              Nothing -> Left (text "Ill-typed call to:" <+> ppr f
                              $$ ppr res_ty <+> text "does not have a shape type.")

      Fun CLFun f -> primCallResultTy_maybe (Fun JustFun f) arg_ty

      Fun SUFFwdPass f@(BaseFunId p _)
        | Just bog_ty <- sufBogTy_maybe p arg_ty
        , Right orig_res_ty <- primCallResultTy_maybe (Fun JustFun f) arg_ty
        -> Right (TypeTuple [orig_res_ty, bog_ty])
        | otherwise
        -> Left (text "Type error in SUF fwd fun:" <+> ppr fun
                 $$ text "Arg ty was" <+> ppr arg_ty)

      Fun SUFRevPass (BaseFunId p orig_arg_ty)
        | TypeTuple [dorig_res_ty, bog_ty] <- arg_ty
        , Just t <- sufRevFunCallResultTy_maybe p orig_arg_ty dorig_res_ty bog_ty
        -> Right t
        | otherwise
        -> Left (text "Type error in SUF rev fun:" <+> ppr fun
             <+> text "Arg ty was:" <+> ppr arg_ty)

      Fun SUFRev f -> primCallResultTy_maybe (Fun (DrvFun Rev) f) arg_ty

primFunCallResultTy :: HasCallStack => PrimFun -> TExpr -> Type
primFunCallResultTy fun args
  = case primFunCallResultTy_maybe fun (typeof args) of
      Just res_ty -> res_ty
      Nothing -> pprTrace "primCallResultTy: Could not determine result type for"
                          (vcat [ ppr fun <+> ppr args
                                , ppr (typeof args)])
                 TypeUnknown

-- Just the base function argument type given that the derived function has
-- argument type derivedFunArgTy, or Nothing if we can't work it out
baseFunArgTy_maybe :: Pretty (BaseFunId n p) => DerivedFun n p -> Type -> Either SDoc (Maybe Type)
baseFunArgTy_maybe derivedFun derivedFunArgTy
  = case derivedFun of
      Fun JustFun _ -> it's derivedFunArgTy
      Fun DrvFun{} _ -> case derivedFunArgTy of
        TypeTuple [baseArgTy', _] -> it's baseArgTy'
        _ -> Left (text "Expected pair argument type to" <+> pprDerivedFun ppr derivedFun
                   $$ text "but instead was:" <+> ppr derivedFunArgTy)
      Fun GradFun{} _ -> it's derivedFunArgTy
      Fun (ShapeFun ds) f -> baseFunArgTy_maybe (Fun ds f) derivedFunArgTy
      Fun CLFun _        -> it's derivedFunArgTy
      Fun SUFFwdPass _ -> it's derivedFunArgTy
      Fun SUFRevPass _ -> don'tKnow
      Fun SUFRev _ -> case derivedFunArgTy of
        TypeTuple [baseArgTy', _] -> it's baseArgTy'
        _ -> Left (text "Expected pair argument type to" <+> pprDerivedFun ppr derivedFun
                   $$ text "but instead was:" <+> ppr derivedFunArgTy)
  where it's = pure . pure
        don'tKnow = pure Nothing

-- If 'f : S -> T' then
--
--     sufBogTy_maybe f S
--
-- returns BOG{f}
sufBogTy_maybe :: PrimFun -> Type -> Maybe Type
sufBogTy_maybe P_SelFun{} arg_ty
  = Just (tangentType arg_ty)

sufBogTy_maybe P_elim arg_ty
  = shapeType arg_ty

sufBogTy_maybe (P_dup _) _
  = Just (TypeTuple [])

sufBogTy_maybe P_size arg_ty
  = Just shape
  where -- FIXME: Use a better encoding of shape
    shape = tangentType arg_ty

sufBogTy_maybe P_index arg_ty
  | TypeTuple [indexType, tensor_ty@(TypeTensor _ _)] <- arg_ty
  -- FIXME: Use a better encoding of shape
  , let shape = tangentType tensor_ty
  = Just (TypeTuple [indexType, shape])

sufBogTy_maybe P_sum arg_ty
  | TypeTensor n _ <- arg_ty
  = Just (tensorIndexType n)

sufBogTy_maybe P_ts_add _
  = Just (TypeTuple [])

sufBogTy_maybe P_ts_dot arg_ty
  = Just arg_ty

sufBogTy_maybe P_constVec _
  = Just (TypeTuple [])

sufBogTy_maybe P_deltaVec arg_ty
  | TypeTuple [indexType, _indexType, _] <- arg_ty
  = Just indexType

sufBogTy_maybe P_eq arg_ty
  = Just (tangentType arg_ty)

sufBogTy_maybe P_ne arg_ty
  = Just (tangentType arg_ty)

sufBogTy_maybe P_Vec_init arg_ty
  = Just (tangentType arg_ty)

sufBogTy_maybe P_ts_scale arg_ty
  = Just arg_ty

sufBogTy_maybe _ _
  = Nothing

-- If 'f : S -> T' then
--
--     sufRevFunCallResultTy_maybe f dT BOG{f}
--
-- returns dS
sufRevFunCallResultTy_maybe :: PrimFun -> Type -> Type -> Type -> Maybe Type
sufRevFunCallResultTy_maybe P_SelFun{} _ _ shape
  = Just shape

sufRevFunCallResultTy_maybe P_elim orig_arg_ty (TypeTuple []) _
  = Just (tangentType orig_arg_ty)

sufRevFunCallResultTy_maybe (P_dup n) _ (TypeTuple arg_tys) (TypeTuple [])
  | arg_ty_first:arg_tys_rest <- arg_tys
  , length arg_tys == n
  , Just res_ty <- eqTypes arg_ty_first arg_tys_rest
  = Just res_ty

sufRevFunCallResultTy_maybe P_size _ _typeIndex shape
  | let tangentType_arg_ty = shape
  = Just tangentType_arg_ty

sufRevFunCallResultTy_maybe P_index _ _elt_ty (TypeTuple [indexType, shape])
  = Just (TypeTuple [tangentType indexType, shape])

sufRevFunCallResultTy_maybe P_sum _ elt_ty indexType
  | Just n <- tensorDimensionFromIndexType_maybe indexType
  = Just (TypeTensor n elt_ty)

sufRevFunCallResultTy_maybe P_ts_add _ dt (TypeTuple [])
  = Just (TypeTuple [dt, dt])

sufRevFunCallResultTy_maybe P_ts_dot _ TypeFloat arg_ty
  = Just arg_ty

sufRevFunCallResultTy_maybe P_constVec _ (TypeTensor n ty) (TypeTuple [])
  | let tangent_index_ty = tangentType (tensorIndexType n)
  = Just (TypeTuple [tangent_index_ty, ty])

sufRevFunCallResultTy_maybe P_deltaVec _ typeTensor_dty indexType
  | TypeTensor _ dty <- typeTensor_dty
  = Just (TypeTuple [tangentType indexType, tangentType indexType, dty])

sufRevFunCallResultTy_maybe P_eq _ (TypeTuple []) tangentType_arg_ty
  = Just tangentType_arg_ty

sufRevFunCallResultTy_maybe P_ne _ (TypeTuple []) tangentType_arg_ty
  = Just tangentType_arg_ty

sufRevFunCallResultTy_maybe P_ts_scale _ dt (TypeTuple [TypeFloat, dt1])
  | dt `eqType` dt1
  = Just (TypeTuple [TypeFloat, dt])

sufRevFunCallResultTy_maybe _ _ _ _
  = Nothing

---------------------------------------
-- This is the function that does the heavy lifting for primitives

primFunCallResultTy_maybe :: PrimFun -> Type -> Maybe Type

primFunCallResultTy_maybe P_fold args
  | TypeTuple [f,acc,v] <- args
  , TypeLam (TypeTuple [a1, b1]) a2 <- f
  , TypeTensor 1 b2 <- v
  , b1 `eqType` b2
  = eqTypes a1 [a2, acc]

primFunCallResultTy_maybe P_lmFold args
  | TypeTuple [ds_zero,f,f',acc,v] <- args
  , TypeLam t1 a1 <- f
  , TypeLam t2 (TypeLM (TypeTuple [s1, t3]) a2) <- f'
  , Just t <- eqTypes t1 [t2, t3]
  , TypeTuple [a3, b1] <- t
  , Just a <- eqTypes a1 [a2, a3, acc]
  , Just _ <- eqTypes ds_zero [tangentType s1]
  , v_ty@(TypeTensor 1 b2) <- v
  , b2 `eqType` b1
  = Just (TypeLM (TypeTuple [s1, TypeTuple [a, v_ty]]) a)
  | otherwise = Nothing

--- Type checking is not comprehensive because we only ever generate
--- RFold through reverse applying to an lmFold, and we assume that is
--- done correctly.  We could add more comprehensive type checking
--- later if we want.
primFunCallResultTy_maybe P_RFold args
  | TypeTuple [_ty_dv,ty_in,_f,_f',acc,v,_dr] <- args
  = Just (TypeTuple [ ty_in
                    , TypeTuple [ tangentType acc
                                , tangentType v]])
  | otherwise = Nothing

--- Type checking is not comprehensive because we only ever generate
--- FFold through forward applying to an lmFold, and we assume that is
--- done correctly.  We could add more comprehensive type checking
--- later if we want.
primFunCallResultTy_maybe P_FFold args
  | TypeTuple [_f,_acc,_v,_df,dacc,_dv] <- args
  = Just dacc
  | otherwise = Nothing

primFunCallResultTy_maybe (P_SelFun i n) (TypeTuple arg_tys)
  | i <= length arg_tys
  , n == length arg_tys
  = Just (arg_tys !! (i - 1))

primFunCallResultTy_maybe fun args
  = case (fun, args) of
      (P_lmZero   , TypeTuple [s, t])                      -> Just (TypeLM s t)
      (P_lmOne    , t)                                     -> Just (TypeLM t t)
      (P_lmScale  , TypeTuple [t, TypeFloat])              -> Just (TypeLM t t)
      (P_lmScaleR , t)                                     -> Just (TypeLM TypeFloat t)
      (P_lmDot    , t)                                     -> Just (TypeLM t TypeFloat)

      (P_lmCompose, TypeTuple [TypeLM _ c, TypeLM a _])    -> Just (TypeLM a c)
      (P_lmAdd    , TypeTuple [TypeLM s1 t1, TypeLM _ _])  -> Just (TypeLM s1 t1)

      (P_lmApply  , TypeTuple [TypeLM s1 t, s2]) | tangentType s1 `eqType` s2 -> Just (tangentType t)
           -- Linar map apply:  lmApply :: (s -o t) -> ds -> dt
      (P_lmApplyR , TypeTuple [t1, TypeLM s t2]) | t1 `eqType` tangentType t2 -> Just (tangentType s)
           -- Reverse apply:  lmApplyR :: dt -> (s -o t) -> ds

      -- The argument tuple to ksc's primitive function "lmVCat" must
      -- have two or more components else we can't deduce its return
      -- type.  (Really the return type ought to be
      --
      --     forall s1. TypeLM s1 (TypeTuple ts)
      --
      -- but we don't have polymorphism in ksc.)  See also
      -- Prim.lmVCat.
      (P_lmVCat   , TypeTuple tys) | Just (ss,ts) <- unzipLMTypes tys
                                     , (s1:ss1) <- ss
                                     , all (== s1) ss1     -> Just (TypeLM s1 (TypeTuple ts))
      (P_lmVCatV  , TypeTensor d (TypeLM s t))             -> Just (TypeLM s (TypeTensor d t))
      (P_lmHCat   , TypeTuple tys) | Just (ss,ts) <- unzipLMTypes tys
                                     , (t1:ts1) <- ts
                                     , all (== t1) ts1     -> Just (TypeLM (TypeTuple ss) t1)
      (P_lmHCatV  , TypeTensor d (TypeLM t s))             -> Just (TypeLM (TypeTensor d t) s)

      -- ($inline f args) forces f to be inlined here
      (P_inline   , t)                                     -> Just t

      -- ($copydown e) requests a copydown of the result of e, in order to reduce memory
      -- usage as far as possible. (In particular, this should reclaim any memory allocated
      -- for temporary variables during the evaluation of e.)
      (P_copydown, t)                                     -> Just t

      -- ($check f rev$f s ds dt) verifies the derivatives rev$f at s in directions ds,dt.
      -- That is, ds and dt should be near-zero elements of the domain and range tangent spaces
      -- and the returned value dt'*Jacobian(f)*ds should be similar to dt'*(f(s+ds)-f(s))
      (P_check    , TypeTuple
                      [ TypeLam s t
                      , TypeLam s_dt ds, s', ds', dt])
                      | s' `eqType` s
                      , tangentType s `eqType` ds
                      , tangentType s' `eqType` ds'
                      , tangentType t `eqType` dt
                      , s_dt `eqType` (TypeTuple [s', dt])
                       -> Just TypeFloat

      -- ($trace e) emits its argument's value to stdout and returns it
      (P_trace    , t)                                       -> Just t

      (P_constVec , TypeTuple [sizeType, t])                 -> tensorTypeFromIndexType_maybe sizeType t
      (P_deltaVec , TypeTuple [sizeType, indexType, t])
        | sizeType `eqType` indexType
        -> tensorTypeFromIndexType_maybe indexType t
      (P_diag     , TypeTuple [TypeInteger,
                                TypeInteger,
                                TypeLam TypeInteger t])      -> Just (TypeTensor 1 (TypeTensor 1 t))

      (P_Vec_init , TypeTuple vals)
        | (s1:ss) <- vals
        , all (== s1) ss                                   -> Just (TypeTensor 1 s1)
      (P_Vec_init , t)                                     -> Just (TypeTensor 1 t)
      (P_build    , TypeTuple
                     [sizeType, TypeLam indexType t])
        | sizeType `eqType` indexType
        -> tensorTypeFromIndexType_maybe indexType t

      -- (print a b c) prints its arguments to stdout with no separators
      (P_print    , _)                                     -> Just TypeInteger
      (P_sumbuild , TypeTuple
                     [sizeType, TypeLam indexType t])
        | sizeType `eqType` indexType
        , isTensorIndexType indexType
        -> Just t
      (P_buildFromSparse, TypeTuple
                         [resultShapeType@TypeTensor{}, loopSizeType, TypeLam loopIndexType t])
        | loopSizeType `eqType` loopIndexType
        , isTensorIndexType loopIndexType
        -> buildFromSparseResultTy_maybe resultShapeType t
      (P_buildFromSparseTupled, TypeTuple
                         [resultShapeType@TypeTuple{}, loopSizeType, TypeLam loopIndexType t])
        | loopSizeType `eqType` loopIndexType
        , isTensorIndexType loopIndexType
        , TypeTuple shapes <- resultShapeType
        , TypeTuple lamty <- t
        -> fmap TypeTuple (zipWithM buildFromSparseResultTy_maybe shapes lamty)
      (P_map      , TypeTuple [TypeLam t1 t2, TypeTensor i t1'])
        | t1 `eqType` t1'
        -> Just (TypeTensor i t2)
      (P_map2     , TypeTuple [TypeLam t tr, TypeTensor i1 t1, TypeTensor i2 t2])
        | t `eqType` TypeTuple [t1, t2]
        , i1 == i2
        -> Just (TypeTensor i1 tr)
      (P_index    , TypeTuple [indexType, TypeTensor d t])
        | indexType `eqType` tensorIndexType d
        -> Just t
      (P_shape    , t)                                     -> shapeType t
      (P_size     , TypeTensor d _)                        -> Just (tensorIndexType d)
      (P_sum      , TypeTensor _ t)                        -> Just t

      (P_unzip    , TypeTensor d (TypeTuple ts))           -> Just (TypeTuple (map (TypeTensor d) ts))

      (P_ts_scale , TypeTuple [TypeFloat,   t]           ) -> Just t
      (P_ts_dot   , TypeTuple [t1, t2])
        | t1 `eqType` t2                                   -> Just TypeFloat
      (P_ts_add   , TypeTuple [t, dt]                    ) -> if dt == tangentType t
                                                                then Just t
                                                                else Nothing
      (P_ts_neg   , t                                    ) -> Just t
      -- For eq and ne we check that the two arguments have the same type
      (P_eq       , TypeTuple [t1, t2]                   )
        | t1 `eqType` t2 -> Just TypeBool
        | otherwise      -> Nothing
      (P_ne       , TypeTuple [t1, t2]                   )
        | t1 `eqType` t2 -> Just TypeBool
        | otherwise      -> Nothing

      (P_delta    , TypeTuple [t1, t2, tret]             )
        | t1 `eqType` t2
        , isTensorIndexType t1
        -> Just tret

      (P_suffwdpass_map, TypeTuple [lam, vec_s] )
        | TypeLam s1 (TypeTuple [t, b]) <- lam
        , TypeTensor i s2 <- vec_s
        , s1 `eqType` s2
        -> Just (TypeTuple [TypeTensor i t, TypeTensor i b])

      (P_sufrevpass_map, TypeTuple [ de1
                                   , TypeLam (TypeTuple [dt1, b1])
                                             (TypeTuple [ds, de2])
                                   , TypeTensor i1 dt2
                                   , TypeTensor i2 b2
                                   ])
        | dt1 `eqType` dt2
        , de1 `eqType` de2
        , b1 `eqType` b2
        , i1 == i2
        -> Just (TypeTuple [TypeTensor i1 ds, de1])


      (P_elim     , _)                                     -> Just (TypeTuple [])
      (P_dup n, t)                                         -> Just (TypeTuple (replicate n t))

      _ -> Nothing

buildFromSparseResultTy_maybe :: Type -> Type -> Maybe Type
buildFromSparseResultTy_maybe (TypeTensor d elemshapety) (TypeTuple [indexty, elemty])
  | indexty `eqType` tensorIndexType d
  , elemshapety `eqType` uncompressedShapeType elemty
  = Just (TypeTensor d elemty)
buildFromSparseResultTy_maybe _ _ = Nothing
