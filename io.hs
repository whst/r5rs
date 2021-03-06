{-# LANGUAGE ExistentialQuantification #-}
import Data.IORef
import System.IO
import System.Environment (getArgs)
import Control.Monad
import Control.Monad.Error
import Text.ParserCombinators.Parsec hiding (spaces)

main :: IO ()
main = do
    args <- getArgs
    if null args then runRepl else runOne args

-- Terminals --
symbol :: Parser Char
symbol = oneOf "!$%&|*+-/:<=>?@^_~#"

readOrThrow :: Parser a -> String -> ThrowsError a
readOrThrow parser input = case parse parser "Lisp" input of
                             Left  err -> throwError $ Parser err
                             Right val -> return val

readExpr :: String -> ThrowsError LispVal
readExpr = readOrThrow parseExpr

readExprList = readOrThrow $ endBy parseExpr spaces

spaces :: Parser ()
spaces = skipMany1 space

-- Data Type definition --
data LispVal = Atom         String
             | List         [LispVal]
             | DottedList   [LispVal] LispVal
             | Number       Integer
             | String       String
             | Bool         Bool
             | Port         Handle
             | IOFunc       ([LispVal] -> IOThrowsError LispVal)
             | PrimitiveFunc ([LispVal] -> ThrowsError LispVal)
             | Func { params  :: [String]
                    , vararg  :: (Maybe String)
                    , body    :: [LispVal]
                    , closure :: Env
                    }

-- Parse Basic Type --
parseString :: Parser LispVal
parseString = do
    char '\"'
    x <- many $ noneOf "\""
    char '\"'
    return $ String x

parseAtom :: Parser LispVal
parseAtom = do
    first <- letter <|> symbol
    rest <- many $ letter <|> symbol <|> digit
    let atom = first : rest
    return $ case atom of
               "#t" -> Bool True
               "#f" -> Bool False
               _    -> Atom atom

parseNumber :: Parser LispVal
parseNumber = liftM (Number . read) $ many1 digit

parseList :: Parser LispVal
parseList = sepBy parseExpr spaces >>= return . List

parseDottedList :: Parser LispVal
parseDottedList = do
    head <- endBy parseExpr spaces
    tail <- char '.' >> spaces >> parseExpr
    return $ DottedList head tail

parseQuoted :: Parser LispVal
parseQuoted = do
    char '\''
    x <- parseExpr
    return $ List [Atom "quote", x]

parseExpr :: Parser LispVal
parseExpr = parseAtom
        <|> parseString
        <|> parseNumber
        <|> parseQuoted
        <|> do char '('
               x <- try parseList <|> parseDottedList
               char ')'
               return x

showVal :: LispVal -> String
showVal (Atom name) = name
showVal (List xs) = "(" ++ unwordsList xs ++ ")"
showVal (DottedList init last) = "(" ++ unwordsList init ++ " . " ++ show last ++ ")"
showVal (Number num) = show num
showVal (String str) = "\"" ++ str ++ "\""
showVal (Bool b) = if b then "#t" else "#f"
showVal (Port _) = "<IO port>"
showVal (IOFunc _) = "<IO primitive>"
showVal (PrimitiveFunc _) = "<primitive>"
showVal (Func {params = args, vararg = varargs, body = body, closure = env}) =
   "(lambda (" ++ unwords (map show args) ++
      (case varargs of
         Nothing -> ""
         Just arg -> " . " ++ arg) ++ ") ...)"

unwordsList :: [LispVal] -> String
unwordsList = unwords . map showVal

instance Show LispVal where show = showVal

-- Eval varoius forms --
eval :: Env -> LispVal -> IOThrowsError LispVal
eval env val@(String _) = return val
eval env val@(Number _) = return val
eval env val@(Bool   _) = return val
eval env     (Atom  id) = getVar env id
eval env (List [Atom "quote", val]) = return val
eval env (List [Atom "load", String filename]) =
                        load filename >>= liftM last . mapM (eval env)
eval env form@(List (Atom "cond" : xs)) = evalCond xs
    where evalCond [] = throwError $ BadSpecialForm "cond里冇为真的表达式" form
          evalCond (List (Atom "else" : vals) : _) = mapM (eval env) vals >>= return . last
          evalCond (List (cond : vals) : rest) = do
              result <- eval env cond
              case result of
                Bool False -> evalCond rest
                Bool True  -> mapM (eval env) vals >>= return . last
                otherwise  -> throwError $ TypeMismatch "boolean" cond
eval env form@(List (Atom "case" : key : xs)) = do
    evaledKey  <- eval env key
    resultList <- evalCase evaledKey xs
    return $ last resultList
        where evalCase k [] = throwError $ BadSpecialForm "No matched list in case" form
              evalCase k (List (Atom "else" : vals) : _) = mapM (eval env) vals
              evalCase k (List (List datums : vals) : rest) = do
                  equalities <- mapM (\x -> liftThrows $ eqv [k, x]) datums
                  if any (\(Bool b) -> b) equalities
                     then mapM (eval env) vals
                     else evalCase k rest
              evalCase k xs = throwError $ BadSpecialForm "Bad case" $ List xs
eval env (List [Atom "if", pred, stmt1, stmt2]) = do
                     result <- eval env pred
                     eval env $ case result of {Bool False -> stmt2; _ -> stmt1}
eval env (List [Atom "set!", Atom var, form]) = eval env form >>= setVar env var
eval env (List [Atom "define", Atom var, form]) = eval env form >>= defineVar env var
eval env (List (Atom "define" : List (Atom var : params) : body)) =
     makeNormalFunc env params body >>= defineVar env var
eval env (List (Atom "define" : DottedList (Atom var : params) varargs : body)) =
     makeVarArgs varargs env params body >>= defineVar env var
eval env (List (Atom "lambda" : List params : body)) =
     makeNormalFunc env params body
eval env (List (Atom "lambda" : DottedList params varargs : body)) =
     makeVarArgs varargs env params body
eval env (List (Atom "lambda" : varargs@(Atom _) : body)) =
     makeVarArgs varargs env [] body
eval env (List (function : args)) = do
    func    <- eval env function
    argVals <- mapM (eval env) args
    apply func argVals
eval env badForm = throwError $ BadSpecialForm "识唔得此形式" badForm

apply :: LispVal -> [LispVal] -> IOThrowsError LispVal
apply (IOFunc func) args = func args
apply (PrimitiveFunc func) args = liftThrows $ func args
apply (Func params varargs body closure) args =
    if num params /= num args && varargs == Nothing
       then throwError $ NumArgs (num params) args
       else (liftIO . bindVars closure $ zip params args) >>= bindVarArgs varargs >>= evalBody
    where num = toInteger . length
          restArgs = drop (length params) args
          evalBody env = liftM last $ mapM (eval env) body
          bindVarArgs arg env = case arg of
              Just argName -> liftIO $ bindVars env [(argName, List restArgs)]
              Nothing -> return env

primeBindings :: IO Env
primeBindings = nullEnv >>= flip bindVars (map (makeFunc IOFunc) ioPrimitives
                                    ++ map (makeFunc PrimitiveFunc) primitives)
    where makeFunc funcType (var, func) = (var, funcType func)

primitives :: [(String, [LispVal] -> ThrowsError LispVal)]
primitives = [("+", numericBinop (+)),
  ("-", numericBinop (-)),
  ("*", numericBinop (*)),
  ("/", numericBinop div),
  ("mod", numericBinop mod),
  ("quotient", numericBinop quot),
  ("remainder", numericBinop rem),
  ("=", numBoolBinop (==)),
  ("<", numBoolBinop (<)),
  (">", numBoolBinop (>)),
  ("/=", numBoolBinop (/=)),
  (">=", numBoolBinop (>=)),
  ("<=", numBoolBinop (<=)),
  ("&&", boolBoolBinop (&&)),
  ("||", boolBoolBinop (||)),
  ("string=?", strBoolBinop (==)),
  ("string<?", strBoolBinop (<)),
  ("string>?", strBoolBinop (>)),
  ("string<=?", strBoolBinop (<=)),
  ("string>=?", strBoolBinop (>=)),
  ("car", car),
  ("cdr", cdr),
  ("cons", cons),
  ("eq?", eqv),
  ("eqv?", eqv),
  ("equal?", equal)]

ioPrimitives :: [(String, [LispVal] -> IOThrowsError LispVal)]
ioPrimitives = [("apply", applyProc),
                ("open-input-file", makePort ReadMode),
                ("open-output-file", makePort WriteMode),
                ("close-input-port", closePort),
                ("close-output-port", closePort),
                ("read", readProc),
                ("write", writeProc),
                ("read-contents", readContents),
                ("read-all", readAll)]

applyProc :: [LispVal] -> IOThrowsError LispVal
applyProc [func, List args] = apply func args
applyProc (func : args)     = apply func args

makePort :: IOMode -> [LispVal] -> IOThrowsError LispVal
makePort mode [String filename] = liftM Port . liftIO $ openFile filename mode

closePort :: [LispVal] -> IOThrowsError LispVal
closePort [Port port] = liftIO $ hClose port >> return (Bool True)
closePort _           = return $ Bool False

readProc :: [LispVal] -> IOThrowsError LispVal
readProc []          = readProc [Port stdin]
readProc [Port port] = liftIO (hGetLine port) >>= liftThrows . readExpr

writeProc :: [LispVal] -> IOThrowsError LispVal
writeProc [obj]            = writeProc [obj, Port stdout]
writeProc [obj, Port port] = liftIO $ hPrint port obj >> return (Bool True)

readContents :: [LispVal] -> IOThrowsError LispVal
readContents [String filename] = liftM String . liftIO $ readFile filename

load :: String -> IOThrowsError [LispVal]
load filename = liftIO (readFile filename) >>= liftThrows . readExprList

readAll :: [LispVal] -> IOThrowsError LispVal
readAll [String filename] = liftM List $ load filename

boolBinop :: (LispVal -> ThrowsError a) -> (a -> a -> Bool) -> [LispVal] -> ThrowsError LispVal
boolBinop unpacker op args = if length args /= 2
                                then throwError $ NumArgs 2 args
                                else do left  <- unpacker $ args !! 0
                                        right <- unpacker $ args !! 1
                                        return $ Bool $ left `op` right

numericBinop :: (Integer -> Integer -> Integer) -> [LispVal] -> ThrowsError LispVal
numericBinop op []            = throwError $ NumArgs 2 []
numericBinop op singleVal@[_] = throwError $ NumArgs 2 singleVal
numericBinop op params        = mapM unpackNum params >>= return . Number . foldl1 op

numBoolBinop  = boolBinop unpackNum
strBoolBinop  = boolBinop unpackStr
boolBoolBinop = boolBinop unpackBool

unpackNum :: LispVal -> ThrowsError Integer
unpackNum (Number n) = return n
unpackNum (String n) = let parsed = reads n in
                           if null parsed
                              then throwError . TypeMismatch "number" $ String n
                              else return . fst $ head parsed
unpackNum (List [n]) = unpackNum n
unpackNum notNum = throwError $ TypeMismatch "number" notNum

unpackStr :: LispVal -> ThrowsError String
unpackStr (String s) = return s
unpackStr (Number s) = return $ show s
unpackStr (Bool   s) = return $ show s
unpackStr notString  = throwError $ TypeMismatch "string" notString

unpackBool :: LispVal -> ThrowsError Bool
unpackBool (Bool b) = return b
unpackBool notBool  = throwError $ TypeMismatch "boolean" notBool

car :: [LispVal] -> ThrowsError LispVal
car [List (x : _)]          = return x
car [DottedList (x : _) _]  = return x
car [badArg]                = throwError $ TypeMismatch "pair" badArg
car badArgList              = throwError $ NumArgs 1 badArgList

cdr :: [LispVal] -> ThrowsError LispVal
cdr [List (_ : xs)]         = return $ List xs
cdr [DottedList [_] x]      = return x
cdr [DottedList (_ : xs) x] = return $ DottedList xs x
cdr [badArg]                = throwError $ TypeMismatch "pair" badArg
cdr badArgList              = throwError $ NumArgs 1 badArgList

cons :: [LispVal] -> ThrowsError LispVal
cons [x, List xs] = return . List $ x : xs
cons [x, DottedList xs xlast] = return $ DottedList (x : xs) xlast
cons [x1, x2] = return $ DottedList [x1] x2
cons badArgList = throwError $ NumArgs 2 badArgList

eqv :: [LispVal] -> ThrowsError LispVal
eqv [(Bool x), (Bool y)]     = return . Bool $ x == y
eqv [(Number x), (Number y)] = return . Bool $ x == y
eqv [(String x), (String y)] = return . Bool $ x == y
eqv [(Atom x), (Atom y)]     = return . Bool $ x == y
eqv [(DottedList xs x), (DottedList ys y)] = eqv [List $ xs ++ [x], List $ ys ++ [y]]
eqv [x@(List _), y@(List _)] = eqvList eqv [x, y]
eqv [_, _]                   = return $ Bool False
eqv badArgList               = throwError $ NumArgs 2 badArgList

data Unpacker = forall a. Eq a => AnyUnpacker (LispVal -> ThrowsError a)

unpackEquals :: LispVal -> LispVal -> Unpacker -> ThrowsError Bool
unpackEquals x y (AnyUnpacker unpacker) = do
    x' <- unpacker x
    y' <- unpacker y
    return $ x' == y'
    `catchError` (const $ return False)

equal :: [LispVal] -> ThrowsError LispVal
equal [x@(List _), y@(List _)] = eqvList equal [x, y]
equal [(DottedList xs x), (DottedList ys y)] = equal [List $ xs ++ [x], List $ ys ++ [y]]
equal [x, y] = do
    primitiveEquals <- liftM or $ mapM (unpackEquals x y) [AnyUnpacker unpackNum,
                                                           AnyUnpacker unpackStr,
                                                           AnyUnpacker unpackBool]
    eqvEquals <- eqv [x, y]
    return . Bool $ primitiveEquals || let (Bool x) = eqvEquals in x
equal badArgList = throwError $ NumArgs 2 badArgList

eqvList :: ([LispVal] -> ThrowsError LispVal) -> [LispVal] -> ThrowsError LispVal
eqvList eqFunc [(List x), (List y)] =
    return . Bool $ (length x == length y) && (all eqvPair $ zip x y)
    where eqvPair (a, b) = case eqFunc [a, b] of
                              Left error    -> False
                              Right (Bool v)-> v

data LispError = NumArgs Integer [LispVal]
               | TypeMismatch   String LispVal
               | Parser         ParseError
               | BadSpecialForm String LispVal
               | NotFunction    String String
               | UnboundVar     String String
               | Default        String

showError :: LispError -> String
showError (UnboundVar message varname)  = message ++ ": " ++ varname
showError (BadSpecialForm message form) = message ++ ": " ++ show form
showError (NotFunction message func)    = message ++ ": " ++ show func
showError (TypeMismatch expected found) = "错误类型: 期望" ++ expected ++ ", 实参:" ++ show found
showError (Parser parseErr)             = "解析错误，位置: " ++ show parseErr

instance Show LispError where show = showError

instance Error LispError where
     noMsg = Default "I'm angry...出现了错误"
     strMsg = Default

type ThrowsError = Either LispError

trapError :: IOThrowsError String -> IOThrowsError String
trapError action = catchError action $ return . show

extractValue :: ThrowsError a -> a
extractValue (Right val) = val

-- for REPL --
flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

readPrompt :: String -> IO (Maybe String)
readPrompt prompt = do
    flushStr prompt
    end <- isEOF
    if end
       then return Nothing
       else do str <- getLine
               return $ if str == "quit" then Nothing else Just str

evalString :: Env -> String -> IO String
evalString env expr =
    runIOThrows . liftM show $ liftThrows (readExpr expr) >>= eval env

evalAndPrint :: Env -> String -> IO ()
evalAndPrint env expr = evalString env expr >>= putStrLn

until_ :: Monad m => m (Maybe a) -> m () -> (a -> m ()) -> m ()
until_ prompt end body = do
    result <- prompt
    case result of
      Nothing -> end
      Just s  -> body s >> until_ prompt end body

runOne :: [String] -> IO ()
runOne args = do
    env <- primeBindings >>= flip bindVars [("args", List . map String $ tail args)]
    err <- runIOThrows . liftM show . eval env $ List [Atom "load", String $ head args]
    hPutStrLn stderr err

runRepl :: IO ()
runRepl = primeBindings >>= until_ (readPrompt "吼啊-> ")
                                (putStrLn "蛤??? 这么快就跑了?") . evalAndPrint

--  IORef  --
type Env = IORef [(String, IORef LispVal)]

nullEnv :: IO Env
nullEnv = newIORef []

type IOThrowsError = ErrorT LispError IO

liftThrows :: ThrowsError a -> IOThrowsError a
liftThrows (Left  err) = throwError err
liftThrows (Right val) = return val

runIOThrows :: IOThrowsError String -> IO String
runIOThrows action = runErrorT (trapError action) >>= return . extractValue

isBound :: Env -> String -> IO Bool
isBound envRef key =
    readIORef envRef >>= return . maybe False (const True) . lookup key

getVar :: Env -> String -> IOThrowsError LispVal
getVar envRef key  =  do
    env <- liftIO $ readIORef envRef
    maybe (throwError $ UnboundVar "仄个变量没听说过" key)
          (liftIO . readIORef)
          (lookup key env)

setVar :: Env -> String -> LispVal -> IOThrowsError LispVal
setVar envRef key val = do
    env <- liftIO $ readIORef envRef
    maybe (throwError $ UnboundVar "设置子虚乌有的变量" key)
          (liftIO . flip writeIORef val)
          (lookup key env)
    return val

defineVar :: Env -> String -> LispVal -> IOThrowsError LispVal
defineVar envRef key val = do
    alreadyDefined <- liftIO $ isBound envRef key
    if alreadyDefined
       then setVar envRef key val >> return val
       else liftIO $ do
           valRef <- newIORef val
           oldEnv <- readIORef envRef
           writeIORef envRef $ (key, valRef) : oldEnv
           return val

bindVars :: Env -> [(String, LispVal)] -> IO Env
bindVars envRef pairs = readIORef envRef >>= extendEnv pairs >>= newIORef
    where extendEnv pairs env = liftM (++ env) $ mapM addBinding pairs
          addBinding (k, v) = newIORef v >>= \ref -> return (k, ref)

makeFunc varargs env params body =
    return $ Func (map showVal params) varargs body env
makeNormalFunc = makeFunc Nothing
makeVarArgs    = makeFunc . Just . showVal
