{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

module AD where

import Lang
import qualified LangUtils
import Prim
import GHC.Stack

-- for unit test
--import Test.Hspec

--------------- Generate names for gradded indentifiers

gradF :: HasCallStack => Fun -> Fun
gradF (Fun f) = GradFun f Fwd
gradF f       = error ("gradF: bad function: " ++ show f)

gradV :: Var -> Var
gradV (Simple x) = Grad x Fwd
gradV v          = error ("gradV: bad variable: " ++ render (ppr v))

gradSelFun :: [TVar] -> TVar -> Int -> TExpr
-- (gradSelFun i n) selects the i'th component of a n-tuple
-- Result expr has type (t1, ..., tn) -o ti
gradSelFun params pi i
  = lmHCat [ if i == j then lmOne $ typeof pi
                       else lmZero (Var pj) (Var pi)
           | (pj,j) <- params `zip` [1..] ]

-------------------------------------------------

isUserFunDef :: TDef -> Bool
isUserFunDef (DefX { def_fun = (TFun _ (Fun _))}) = True
isUserFunDef _ = False

filterGradFuns :: [TDef] -> [TDef]
filterGradFuns = filter isUserFunDef

gradDefs :: HasCallStack => [TDef] -> [TDef]
gradDefs = map gradDef . filterGradFuns

gradDef :: HasCallStack => TDef -> TDef
gradDef (DefX { def_fun = f, def_args = params, def_rhs = rhs })
  = DefX { def_fun = gradTFun sty f
         , def_args = params
         , def_rhs = mkLets lets (gradE s rhs) }
  where
    param1 :: TExpr
    param1 = mkTuple (map Var params)
    sty = typeof param1
    svar = TVar sty $ Simple "$arg"

    s = Var svar

    lets =  (svar, param1)
            :
            case params of
             [p] -> [ (gradTVar s p, lmOne (typeof p)) ]
             _   -> [ (gradTVar s p, gradSelFun params p i)
                    | (p,i) <- params `zip` [1..] ]


-- s -> (Expr :: t) -> (Expr :: s -o t)
gradE :: HasCallStack => TExpr -> TExpr -> TExpr
gradE s e@(Konst _)    = lmZero s e
gradE s (Var tv)       = Var (gradTVar s tv)
gradE s (Assert e1 e2) = Assert e1 (gradE s e2)
gradE s (Tuple es)     = lmVCat (map (gradE s) es)
gradE s (If b t e)     = If b (gradE s t) (gradE s e)
gradE _ e@(Lam {})     = pprPanic "gradE: can't deal with lambda yet" (ppr e)
gradE s (Let v e1 e2)  = mkLet v e1                       $
                         mkLet (gradTVar s v) (gradE s e1) $
                         gradE s e2

-- grad[ build (\i.e ]
--  = B (\i. let Di = 0 in grad[e])
-- We need the Di binding in case 'i' is mentioned in
-- grad[e], e.g. build (\i. power(x, i))
gradE s (Call f [n, Lam ti body])
  | f `isThePrimFun` "build"
  = lmBuild n $ Lam ti $
    mkLet (gradTVar s ti) (lmZero s $ Var ti) $
    gradE s body

-- Currently ignoring $inline when gradding.  Perhaps we should
-- perform the inlining before gradding.
gradE s (Call f [arg])
  | f `isThePrimFun` "$inline"
  = gradE s arg

gradE s (Call f args)
  = Call gf args `lmCompose` lmVCat (map (gradE s) args)
  where
    gf = gradTFun (mkTupleTy (map typeof args)) f

gradTFun :: HasCallStack => Type -> TFun -> TFun
gradTFun arg_ty (TFun res_ty f)
  = TFun (TypeLM arg_ty res_ty) (gradF f)

gradTVar :: TExpr -> TVar -> TVar
gradTVar s (TVar ty v) = TVar (TypeLM (typeof s) ty) (gradV v)

---------------------------------

-- Apply-to-dx
--
-- Local bindings of type (S -o T)
-- are transformed to ones of type T

applyD :: TDef -> TDef
--   R$f :: S1 S2   -> (T -o (S1,S2))
-- rev$f :: S1 S2 T -> (S1,S2)
applyD (DefX (TFun (TypeLM s t) (GradFun f Rev)) vars rhs)
  = DefX (TFun (tangentType t) (DrvFun f Rev)) (vars ++ [dr]) $
    lmApply rhs $ Var dr
  where
    dr = TVar (tangentType s) $ Delta "r"

--   D$f :: S1 S2       -> ((S1,S2) -o T)
-- rev$f :: S1 S2 S1 S2 -> T
applyD (DefX (TFun (TypeLM _ t) (GradFun f Fwd)) vars rhs)
  = DefX (TFun (tangentType t) (DrvFun f Fwd)) (vars ++ dvars) $
    lmApply rhs (mkTuple $ map Var dvars)
  where
    dvars = map to_delta vars
    to_delta (TVar ty (Simple x)) = TVar (tangentType ty) (Delta x)

applyDefs :: [TDef] -> [TDef]
applyDefs = map applyD

---------------------------------
-- Transpose

transposeD :: TDef -> TDef
transposeD (DefX (TFun (TypeLM s t) (GradFun f d)) args rhs)
  = DefX (TFun (TypeLM t s) (GradFun f (flipMode d))) args $
    lmTranspose rhs

---------------------------------
-- Check
--
-- Generates code for
--
-- f$check(x_1, .., x_n, d$x_1, .., d$x_n, d$r)
--   = (<(d$x_1, ..., d$x_n), rev$f(x_1, ..., x_n, d$r)>
--      - <f(x_1 + d$x_1, ..., x_n + d$x_n) - f(x_1, ..., x_n), d$r>)
--     / norm(d$x_1, .., d$x_n)
--
-- i.e. what should be small (when (d$x_1, .., d$x_n) is) if our
-- reverse mode generated code is correct.

checkD :: TDef -> TDef
checkD (DefX tf@(TFun retType (Fun f_id)) vars _)
  = DefX (TFun TypeFloat (CheckFun f_id)) checkVars checkRhs
  where
    checkRhs  = pDiv (pSub (pDot dxs (Call frev xs_dr))
                           (pDot (myPSub (pToTangent (Call tf xs_plus_dxs))
                                         (pToTangent (Call tf xs)))
                                 (Var dr)))
                     (pNorm dxs)
    checkVars = vars ++ dvars ++ [dr]

    myPSub x y = pAdd x (pNeg y)

    frev = TFun frevRetType (DrvFun f_id Rev)

    frevRetType = let typeOfTVar (TVar t _) = t
                  in tangentType $ case map typeOfTVar vars of
                    [tvar] -> tvar
                    tvars  -> TypeTuple tvars

    dxs_l    = map Var dvars
    xs_l     = map Var vars

    dxs         = mkTuple dxs_l
    xs_plus_dxs = zipWith pTangentAdd xs_l dxs_l
    xs          = xs_l
    xs_dr       = xs_l ++ [Var dr]


    -- NB These have duplication with applyD
    dvars = map to_delta vars
    dr = LangUtils.newVarNotIn (tangentType retType) (Tuple dxs_l)
    to_delta (TVar ty (Simple x)) = TVar (tangentType ty) (Delta x)

----------------------------------
--- Unit test

{-

-- TODO make this work
test_AD =
  hspec $ do
    let e1 = runParserOrPanic pDef "(def f ((x : Float)) (* x 2.0))"
    let (env,ae1) = annotDef e1
    let de1_expected = runParserOrPanic pDef "(def D$f ((x : Float)) (lmScale Float 2.0))"
    let (env1,ade1_expected) = annotDef de1_expected
    let ade1 = gradDef emptyST ae1
    describe "AD" $ do
      it "AD" $
        ade1 `shouldBe` ade1_expected
-}
