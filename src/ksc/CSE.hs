module CSE where

import Lang
import Prim
import LangUtils( substE )
import Rules
import Annotate( GblSymTab )
import Text.PrettyPrint
import ANF
import Opt
import KMonad
import qualified Data.Map as M

type CSEf = TFun
type CSEb = TVar

cseDefs :: RuleBase -> GblSymTab -> [DefX CSEf CSEb]
        -> KM (GblSymTab, [DefX CSEf CSEb])
-- The returned GblSymTab contains the CSE'd definitions
cseDefs rb gst defs
  = do { anf_defs <- anfDefs defs
--       ; banner "ANF'd"
--       ; displayN anf_defs

       ; let cse_defs = map cseD anf_defs
--       ; banner "CSE'd"
--       ; displayN anf_defs

             -- cseE turns   let x = e in ..let y = e in ...
             --      into    let x = e in ..let y = x in ...
            -- Then optDefs substitutes x for y

       ; return $ optDefs rb gst cse_defs
      }

---------------------------------
cseD :: DefX CSEf CSEb -> DefX CSEf CSEb
cseD (DefX f1 args rhs) = DefX f1 args (cseE M.empty rhs)

cseE :: M.Map (ExprX CSEf CSEb) (ExprX CSEf CSEb) -> ExprX CSEf CSEb -> ExprX CSEf CSEb
cseE cse_env (Let v rhs body)
  | Just rhs'' <- M.lookup rhs' cse_env
  = Let v rhs'' (cseE_check cse_env body)
  | otherwise
  = Let v rhs'  (cseE_check cse_env' body)
  where
    rhs' = cseE cse_env rhs
    cse_env' = M.insert rhs' (Var v) cse_env

cseE cse_env (Assert e1 e2)
 | Call eq (Tuple [e1a, e1b]) <- e1'
 , eq `isThePrimFun` "=="
 , let cse_env' = M.map (substAssert e1a e1b) cse_env
 = Assert e1' (cseE cse_env' e2)
 | otherwise
 = Assert e1' (cseE cse_env e2)
 where
   e1' = cseE cse_env e1

cseE cse_env (If e1 e2 e3)
  = If (cseE_check cse_env e1)
       (cseE_check cse_env e2)
       (cseE_check cse_env e3)

cseE cse_env (Call f e)  = Call f (cseE_check cse_env e)
cseE cse_env (Tuple es)  = Tuple (map (cseE_check cse_env) es)
cseE cse_env (App e1 e2) = App (cseE_check cse_env e1)
                               (cseE_check cse_env e2)

cseE cse_env (Lam v e) = Lam v (cseE cse_env e)
  -- Watch out: the variable might capture things in cse_env

cseE _ e = e  -- For now: lambda, app, const, var

cseE_check :: M.Map (ExprX CSEf CSEb) (ExprX CSEf CSEb) -> ExprX CSEf CSEb -> ExprX CSEf CSEb
-- Look up the entire expression in the envt
cseE_check cse_env e
  | Just e'' <- M.lookup e' cse_env
  = e''
  | otherwise
  = e'
  where
    e' = cseE cse_env e

substAssert (Var v) e1b = substE (M.insert v e1b M.empty)
substAssert e1a (Var v) = substE (M.insert v e1a M.empty)
substAssert _ _ = \e -> e