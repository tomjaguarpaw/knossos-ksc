-- | Knossos-to-Futhark translator.  Makes some transformations to
-- avoid known-inefficient Futhark expressions.  Linear maps are not
-- handled at all - it is expected that other transformations
-- specialise these away first.
module Ksc.Futhark (toFuthark, Def) where

import           Data.Int
import           Data.List
import           Prelude                 hiding ( (<>) )

import qualified Lang                    as L
import Lang (Pretty(..), text, render, empty, parensIf,
             (<>), (<+>), ($$), parens, brackets, punctuate, sep,
             integer, double, comma)

--------------------------
-- Futhark AST definition
--------------------------

type Name = String

data Entry = Entry | NotEntry
           deriving (Eq, Ord, Show)

data Param = Param { paramName :: Name
                   , paramType :: Type
                   }
  deriving (Eq, Ord, Show)

data TypeParam = TypeParam { typeParamName :: Name }
               | SizeParam { typeParamName :: Name }
         deriving (Eq, Ord, Show)

data Def = DefFun Entry Name [TypeParam] [Param] (Maybe Type) Exp
         | DefComment String
         deriving (Eq, Ord, Show)

data Const = ConstI32 Int32
           | ConstF32 Float
           | ConstF64 Double
           | ConstBool Bool
           | ConstString String
         deriving (Eq, Ord, Show)

data Pat = PatId Name
         | PatTuple [Name]
         | PatAscript Pat Type
         deriving (Eq, Ord, Show)

-- | Real Futhark is more general than what is encoded in this type.
data Exp = Var Name
         | Const Const
         | If Exp Exp Exp
         | Let Pat Exp Exp
         | BinOp String Exp Exp
         | ExpTuple [Exp]
         | Call Exp [Exp]
         | Lambda [Pat] Exp
         | Project Exp String
         | SectionProject String
         | Index Exp [Exp]
         deriving (Eq, Ord, Show)

data Dim = DimAny | DimConst Int32 | DimNamed Name
          deriving (Eq, Ord, Show)

data Type = I32 | F32 | F64 | Bool | Tuple [Type] | Array Dim Type
          deriving (Eq, Ord, Show)

------------------------------
-- Pretty printer for Futhark
------------------------------

isInfix :: String -> Bool
isInfix = all (`elem` "+-*/%=!><|&^.")

instance Pretty Dim where
  ppr DimAny = empty
  ppr (DimConst x) = integer $ toInteger x
  ppr (DimNamed v) = text v

instance Pretty Type where
  ppr I32 = text "i32"
  ppr F32 = text "f32"
  ppr F64 = text "f64"
  ppr Bool = text "bool"
  ppr (Tuple ts) =
    parens $ sep $ punctuate comma $ map ppr ts
  ppr (Array d t) =
    brackets (ppr d) <> ppr t

instance Pretty TypeParam where
  ppr (TypeParam t) = text "'" <> text t
  ppr (SizeParam v) = brackets $ text v

instance Pretty Param where
  ppr (Param v t) = parens $ text v <> text ":" <+> ppr t

instance Pretty Def where
  ppr (DefFun entry fname tparams params ret rhs) =
    L.hang (let' entry <+> text fname <+>
            L.fsep (map ppr tparams) <+>
            L.fsep (map ppr params) <+>
            (maybe empty ((text ":" <+>) . ppr) ret) <+> text "=")
    2 (ppr rhs)
    where let' Entry = text "entry"
          let' NotEntry = text "let"
  ppr (DefComment s) =
    text $ intercalate "\n" $ map ("-- "++) $ lines s

instance Pretty Const where
  ppr (ConstI32 x) = integer $ toInteger x
  ppr (ConstF32 x) = double $ fromRational $ toRational x
  ppr (ConstF64 x) = double x
  ppr (ConstBool x) = if x then text "true" else text "false"
  ppr (ConstString s) = text $ show s

instance Pretty Pat where
  ppr (PatId v) = text v
  ppr (PatTuple pats) = sep $ intersperse (text ", ") $ map ppr pats
  ppr (PatAscript p t) = parens $ ppr p <> text ":" <+> ppr t

precedence, rprecedence :: String -> Int
precedence s
  | any (`isPrefixOf` s) ["&&", "||"] = 1
precedence s
  | any (`isPrefixOf` s) ["&", "|", "^"] = 2
precedence s
  | any (`isPrefixOf` s) [">>", "<<"] = 3
precedence s
  | any (`isPrefixOf` s) ["==", "!=", "<", ">"] = 2
precedence s
  | any (`isPrefixOf` s) ["**"] = 6
precedence s
  | any (`isPrefixOf` s) ["+", "-"] = 4
precedence s
  | any (`isPrefixOf` s) ["*", "/", "%"] = 5
precedence _ = 0

rprecedence s
  | any (`isPrefixOf` s) ["-", "/"] = 10
rprecedence s = precedence s

instance Pretty Exp where
  ppr = pprPrec (-1)
  pprPrec _ (Var v)
    | isInfix v = parens $ text v
    | otherwise = text v
  pprPrec _ (Const k) = ppr k
  pprPrec p (If cond te fe) =
    parensIf p 0 $
    text "if" <+> ppr cond $$
    text "then" <+> ppr te $$
    text "else" <+> ppr fe
  pprPrec p (Let pat rhs body) =
    parensIf p 0 $
    let bef = text "let" <+> ppr pat <+> text "=" <+> ppr rhs
    in case body of
         Let{} -> bef $$ ppr body
         _ -> bef $$ text "in" <+> ppr body
  pprPrec p (BinOp op e1 e2) =
    parensIf p (precedence op) $
    pprPrec (precedence op) e1 <+> text op <+> pprPrec (rprecedence op) e2
  pprPrec _ (ExpTuple es) =
    parens $ sep $ punctuate comma $ map ppr es
  pprPrec p (Call f args) =
    parensIf p 10 $
    ppr f <+> sep (map (pprPrec 10) args)
  pprPrec _ (Lambda params body) =
    parens $ text "\\" <> L.hang (sep (map ppr params) <+> text "->")
    2 (ppr body)
  pprPrec _ (Project e field) =
    e' <> text "." <> text field
    where e' = case e of Var{} -> ppr e
                         _     -> parens $ ppr e
  pprPrec _ (Index arr is) =
    arr' <> brackets (sep $ intersperse (text ",") $ map ppr is)
    where arr' = case arr of Var{} -> ppr arr
                             _     -> parens $ ppr arr
  pprPrec _ (SectionProject f) =
    parens $ text "." <> text f

------------------------------
-- TDef-to-Futhark conversion
------------------------------

primType :: Type -> Bool
primType Array{} = False
primType Tuple{} = False
primType _ = True

-- | Futhark does not support dollar signs in names, so replace them
-- with underscores (but not leading, because that's also not
-- permitted).  Also, as a hack, rewrite some known reserved names by
-- tailing an underscore.
escape :: String -> Name
escape = noLeadingUnderscore . escapeReserved . map escape'
  where escape' '$' = '_'
        escape' c = c

        escapeReserved s
          | s `elem` reserved = s ++ "_"
          | otherwise = s

        reserved = ["val"]

        noLeadingUnderscore ('_' : s) = 'u' : '_' : s
        noLeadingUnderscore s = s

toName :: Pretty x => x -> Name
toName = escape . render . ppr

toFutharkType :: L.Type -> Type
toFutharkType L.TypeInteger = I32
toFutharkType L.TypeFloat = F64
toFutharkType L.TypeBool = Bool
toFutharkType (L.TypeTuple ts) = Tuple $ map toFutharkType ts
toFutharkType (L.TypeVec (L.Var (L.TVar _ (L.Simple v))) t) =
  Array (DimNamed v) $ toFutharkType t
toFutharkType (L.TypeVec (L.Konst (L.KSize x)) t) =
  Array (DimConst $ fromInteger x) $ toFutharkType t
toFutharkType (L.TypeVec _ t) =
  Array DimAny $ toFutharkType t
toFutharkType t =
  error $ "toFutharkType: unhandled " ++ error (show t)

sizesInType :: L.Type -> [Name]
sizesInType (L.TypeVec (L.Var (L.TVar _ (L.Simple v))) t) = v : sizesInType t
sizesInType (L.TypeTuple ts) = concatMap sizesInType ts
sizesInType _ = []

toFutharkParam :: L.TVar -> (Param, [TypeParam])
toFutharkParam (L.TVar t v) =
  (Param (toName v) $ toFutharkType t,
   map SizeParam $ sizesInType t)

toFutharkConst :: L.Konst -> Const
toFutharkConst (L.KInteger x) = ConstI32 $ fromInteger x
toFutharkConst (L.KFloat x) = ConstF64 $ fromRational $ toRational x
toFutharkConst (L.KSize x) = ConstI32 $ fromInteger x
toFutharkConst (L.KBool x) = ConstBool x
toFutharkConst (L.KString x) = ConstString x

plusFunction :: Type -> Exp
plusFunction I32 = Var "+"
plusFunction F32 = Var "+"
plusFunction F64 = Var "+"
plusFunction Bool = Var "||"
plusFunction (Array _ t)  = Call (Var "map2") [plusFunction t]
plusFunction (Tuple ts)  =
  Lambda [PatId "x" `PatAscript` Tuple ts,
          PatId "y" `PatAscript` Tuple ts] $
  ExpTuple $ zipWith mkPlus [(1::Int)..] ts
  where mkPlus i t =
          Call (plusFunction t) [Project (Var "x") (show i),
                                 Project (Var "y") (show i)]

zeroValue :: Type -> Exp
zeroValue I32 = Const $ ConstI32 0
zeroValue F32 = Const $ ConstF32 0
zeroValue F64 = Const $ ConstF64 0
zeroValue Bool = Const $ ConstBool False
zeroValue (Array d t) = Call (Var "replicate") [d', zeroValue t]
  where d' = case d of DimNamed v -> Var v
                       DimConst k -> Const $ ConstI32 k
                       DimAny -> error "zeroValue: DimAny"
zeroValue (Tuple ts) = ExpTuple $ map zeroValue ts

toFutharkExp :: L.TExpr -> Exp
toFutharkExp (L.Konst k) = Const $ toFutharkConst k
toFutharkExp (L.Var v) = Var $ toName v
toFutharkExp (L.If cond te fe) = If (toFutharkExp cond) (toFutharkExp te) (toFutharkExp fe)
toFutharkExp (L.Let (L.TVar _ (L.Simple v)) e1 body) =
  Let (PatId v) (toFutharkExp e1) (toFutharkExp body)
toFutharkExp (L.Tuple es) =
  ExpTuple $ map toFutharkExp es
toFutharkExp (L.Lam (L.TVar _ v) body) =
  Lambda [PatId $ toName v] $ toFutharkExp body
toFutharkExp (L.Assert _ e) =
  toFutharkExp e
toFutharkExp (L.Call f args) =
  toCall f args
toFutharkExp e =
  error $ "toFutharkExp: unhandled " ++ show e

letPat :: Name -> Exp -> (Exp -> Exp) -> Exp
letPat _ (Var v) f = f $ Var v
letPat x e f = Let (PatId x) e $ f $ Var x

-- | Split sumbuilds of tuples into independent sumbuilds, to avoid
-- confusing the Futhark compiler.
sumbuild :: L.Type -> Exp -> Exp
sumbuild (L.TypeTuple []) _ =
  ExpTuple []
sumbuild (L.TypeTuple ts) xs =
  letPat "xs" xs $ \xs' ->
  ExpTuple $ zipWith sumbuild ts
  [Call (Var "map") [SectionProject (show i), xs'] | i <- [1..length ts] ]
sumbuild ret xs =
  Call (Var "sumbuild") [plusFunction ret', zeroValue ret', xs]
  where ret' = toFutharkType ret

callPrimFun :: String -> L.Type -> [L.TExpr] -> Exp
callPrimFun "deltaVec" ret [n, i, v] =
  Call (Var "deltaVec") [zeroValue ret',
                         toFutharkExp n,
                         toFutharkExp i,
                         toFutharkExp v]
  where Array _ ret' = toFutharkType ret

callPrimFun "delta" ret [i, j, v] =
  Call (Var "delta") [zeroValue ret',
                      toFutharkExp i,
                      toFutharkExp j,
                      toFutharkExp v]
  where ret' = toFutharkType ret

callPrimFun "sumbuild" ret [n, f] =
  sumbuild ret $ Call (Var "tabulate") [toFutharkExp n, toFutharkExp f]

callPrimFun "index" _ [i, arr] =
  case toFutharkExp arr of
    Index arr' is ->
      Index arr' $ is ++ [toFutharkExp i]
    arr' ->
      Index arr' [toFutharkExp i]

callPrimFun "pr" _ es =
  ExpTuple $ map toFutharkExp es

callPrimFun f _ args =
  Call (Var (escape f)) $ map toFutharkExp args

-- | Handling function calls is the most complicated bit, because
-- Futhark has different semantics than the source language (and C++).
-- In particular, no ad-hoc polymorphism.  We handle this on a
-- case-by-case basis.
toCall :: L.TFun -> [L.TExpr] -> Exp
toCall (L.TFun ret f) [e1, e2]
  | isInfix (toName f) =
    -- This might be a vectorised operator - if so, we have to put
    -- enough 'map2's on top to make the types work out.
      if primType ret'
      then BinOp (toName f) (toFutharkExp e1) (toFutharkExp e2)
      else Call (plusFunction ret') [toFutharkExp e1, toFutharkExp e2]
  where ret' = toFutharkType ret

toCall (L.TFun _ (L.Fun (L.SelFun f _))) [e] =
  Project (toFutharkExp e) $ show f

toCall (L.TFun _ (L.Fun L.SelFun{})) args =
  error $ "toCall: cannot project arguments: " ++ show args

toCall (L.TFun ret (L.Fun (L.PrimFun f))) args =
  callPrimFun f ret args

toCall f@(L.TFun _ (L.Fun L.UserFun{})) args =
  Call (Var (toName f)) $ map toFutharkExp args

toCall f@(L.TFun _ L.GradFun{}) args =
  Call (Var (toName f)) $ map toFutharkExp args

toCall f@(L.TFun _ L.DrvFun{}) args =
  Call (Var (toName f)) $ map toFutharkExp args

toFuthark :: L.TDef -> Def
toFuthark (L.Def f args res_ty (L.UserRhs e)) =
  DefFun entry fname (filter notParam $ nub $ concat size_params)
  params res_ty' (toFutharkExp e)
  where fname = toName f
        entry = if fname == "main" then Entry else NotEntry
        -- We do not insert a return type annotation on entry points
        -- because they use the 'pr' pseudo-function, which we
        -- translate in a non-type-preserving way.
        res_ty' = case entry of Entry -> Nothing
                                NotEntry -> Just $ toFutharkType res_ty
        (params, size_params) = unzip $ map toFutharkParam args
        notParam tp = typeParamName tp `notElem` map paramName params
toFuthark d =
  DefComment $ render $ ppr d