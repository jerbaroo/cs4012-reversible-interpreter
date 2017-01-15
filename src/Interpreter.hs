module Interpreter where

import qualified Data.Map as Map
import           Control.Monad.Except
import           Control.Monad.State
import Expr

-- The statement language.
data Statement =
      Assign Name Expr
    | If Expr Statement Statement
    | While Expr Statement
    | Print Expr
    | Seq Statement Statement
    | Try Statement Statement
    | Pass
    deriving (Eq, Read, Show)

-- History consists of all previous statements and maybe value of a variable
-- prior to assignment.
type HistoryItem = (Statement, Maybe (Name, Val))
type History     = [HistoryItem]

-- State in the SEval monad consists of the history of previous statements, the
-- current evaluation environment and the statements remaining to be evaluated.
data IState = IState {
        iSHist :: History,
        iSEnv  :: Env
    } deriving Show

newIState :: IState
newIState = IState { iSHist = [], iSEnv = Map.empty }

-- Get and set state environment.
getEnv :: SEval Env
getEnv = iSEnv <$> get

setEnv :: Env -> SEval ()
setEnv env = modify (\s -> s { iSEnv = env })

modifyEnv :: (Env -> Env) -> SEval ()
modifyEnv f = modify (\s -> s { iSEnv = f (iSEnv s) })

-- Save a statement and possible assignment to history.
save :: Statement -> Maybe Name -> SEval ()
save statement maybeName = do
    history <- getHistory
    case maybeName of
        Nothing   -> saveNothing history
        Just name -> do
            env <- getEnv
            case Map.lookup name env of
                Nothing  -> saveNothing history
                Just val -> saveVal history name val

    where saveNothing hist = setHistory $ hist ++ [(statement, Nothing)]
          saveVal hist name val =
              setHistory $ hist ++ [(statement, Just (name, val))]

-- Get and set state history.
getHistory :: SEval History
getHistory = iSHist <$> get

setHistory :: History -> SEval ()
setHistory history = modify (\s -> s { iSHist = history })

-- Print interpreter output.
putInfo :: String -> SEval ()
putInfo str = liftIO $ putStrLn $ "> " ++ str

data SError = BackError Int | StrError String deriving Show

-- Print and throw error.
throwSErrorStr :: String -> SEval a
throwSErrorStr err = do
    putInfo $ "ERR: " ++ err
    throwError $ StrError err

-- Monadic style statement evaluator.
type SEval a = StateT IState (ExceptT SError IO) a

-- Run the SEval monad where state contains the given statements.
runSEval :: SEval a -> IO (Either SError (a, IState))
runSEval sEvalA = runExceptT $ runStateT sEvalA newIState

-- Evaluate an expression in the SEval monad.

sExpr :: Expr -> SEval Val
sExpr expr = do
    env <- getEnv
    case runEval env (eval expr) of
        Left  err -> throwSErrorStr err
        Right val -> return val

sExprB :: Expr -> SEval Bool
sExprB expr = do
    val <- sExpr expr
    case val of
        B bool -> return bool
        a      -> throwSErrorStr $ "Expected B Bool, got " ++ show a

-- Statement handlers for the interpreter -------------------------------------

-- In case a user has decided to step back through the program, this function
-- catches a step back error, once we have stepped back enough then
-- evaluation is resumed.
sEval :: Statement -> SEval ()
sEval stmt = do
    state <- get
    putInfo $ "Running: " ++ safeShow stmt
    sEval' stmt `catchError` handler state
    where handler state (BackError n)
            | n >  1 = throwError $ BackError (n - 1)
            | n == 1 = do
                putInfo $ "Stepped back to " ++ safeShow stmt
                put state
                sEval stmt
          handler _ err = throwError err

-- This is the function which actually evaluates statements.
sEval' :: Statement -> SEval ()

sEval' stmt@(Assign name expr) = do
    save stmt $ Just name
    env <- getEnv
    val <- sExpr expr
    setEnv $ Map.insert name val env
    putInfo $ concat ["Assigned ", show val, " to ", show name]

sEval' stmt@(If expr sTrue sFalse) = do
    save stmt Nothing
    val <- sExprB expr
    putInfo $ "If guard " ++ show val
    if   val
    then prompt sTrue
    else prompt sFalse

sEval' stmt@(While expr body) = do
    save stmt Nothing
    val <- sExprB expr
    putInfo $ "While guard " ++ show val
    when val $ do
      prompt body
      putInfo "While iteration finished"
      prompt stmt

sEval' stmt@(Print expr) = do
    save stmt Nothing
    liftIO $ putStrLn $ "Print: " ++ show expr

sEval' stmt@(Seq s1 s2) = do
    save stmt Nothing
    prompt s1
    prompt s2

sEval' stmt@(Try sTry sCatch) = do
    save stmt Nothing
    prompt sTry `catchError` handler
    where handler (StrError err) = do
            putInfo $ "Caught error: " ++ show err
            prompt sCatch
          handler err = throwError err

sEval' Pass = save Pass Nothing

-- Interactive prompt for a statement.
prompt :: Statement -> SEval ()
prompt stmt = do
    putInfo $ "Next: " ++ safeShow stmt
    putInfo $ "c (continue) / b (back) / i X (inspect var X) / " ++
              "e (environement) / q (quit)"
    input <- liftIO getLine
    case input of
        "c"              -> sEval stmt
        "b"              -> throwError $ BackError 2
        ['i', ' ', name] -> printVarHistory [name] >> prompt stmt
        "e"              -> printEnv               >> prompt stmt
        "q"              -> fail "quitting..."
        _                -> putInfo "bad input"    >> prompt stmt

-- Run the prompt on a statement, catching any errors.
runInterpreter :: Statement -> IO ()
runInterpreter statement = void $ runSEval catchRoot
    where catchRoot = sEval statement `catchError` handler
          handler (BackError _) = putInfo "First statement" >> catchRoot
          handler _             = putInfo "Uncaught error"

-- Inspection functions -------------------------------------------------------

-- Interactive prompt to inspect the history of variables.
inspectPrompt :: SEval ()
inspectPrompt = do
    putInfo "i X (inspect X) / e (current environement) / q (quit inspection)"
    input <- liftIO getLine
    case input of
        "q"              -> return ()
        "e"              -> printEnv               >> inspectPrompt
        _                -> putInfo "bad input"    >> inspectPrompt

-- Prints the history of a variable and its current value.
printVarHistory :: Name -> SEval ()
printVarHistory name = do
    history <- getHistory
    mapM_ (printHistoryItemIfName name) history
    printCurrentVar name

-- Prints a statement and value of a variable prior to its execution IF that
-- variable is of given name.
printHistoryItemIfName :: Name -> HistoryItem -> SEval ()
printHistoryItemIfName name (_, maybeVar) =
    case maybeVar of
        Nothing           -> return ()
        Just (name', val) ->
            when (name == name') $ putInfo $ concat [name, " = ", show val]

-- Prints the current value of a variable.
printCurrentVar :: Name -> SEval ()
printCurrentVar name = do
    env <- getEnv
    case Map.lookup name env of
        Nothing  -> putInfo $ name ++ " is undefined"
        Just val -> putInfo $ concat [name, " = ", show val]

-- Prints the current environment.
printEnv :: SEval ()
printEnv = do
    env <- getEnv
    printEnv' $ Map.toList env

printEnv' :: [(Name, Val)] -> SEval ()
printEnv' [] = return ()
printEnv' ((name, val):xs) = do
    putInfo $ concat [name, " = ", show val]
    printEnv' xs

-- Show upto n chars of a showable value.
safeShow :: Show a => a -> String
safeShow = safeTake . show

-- Take upto n chars of a string if there are enough.
safeTake :: String -> String
safeTake = safeTake' 30

safeTake' :: Int -> String -> String
safeTake' _ [] = []
safeTake' n (x:xs)
    | n > 0     = x : safeTake' (n - 1) xs
    | otherwise = "..."