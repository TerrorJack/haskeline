{- | 

A rich user interface for line input in command-line programs.  Haskeline is
Unicode-aware and runs both on POSIX-compatible systems and on Windows.  

Users may customize the interface with a @~/.haskeline@ file; see
<http://trac.haskell.org/haskeline/wiki/UserPrefs> for more information.

An example use of this library for a simple read-eval-print loop is the
following:

> import System.Console.Haskeline
> 
> main :: IO ()
> main = runInputT defaultSettings loop
>    where 
>        loop :: InputT IO ()
>        loop = do
>            minput <- getInputLine "% "
>            case minput of
>                Nothing -> return ()
>                Just "quit" -> return ()
>                Just input -> do outputStrLn $ "Input was: " ++ input
>                                 loop

If either 'stdin' or 'stdout' is not connected to a terminal (for example, piped from another
process), Haskeline will treat it as a UTF-8-encoded file handle.  

-}


module System.Console.Haskeline(
                    -- * Main functions
                    -- ** The InputT monad transformer
                    InputT,
                    runInputT,
                    runInputTWithPrefs,
                    -- ** Reading user input
                    getInputLine,
                    getInputChar,
                    -- ** Outputting text
                    outputStr,
                    outputStrLn,
                    -- * Settings
                    Settings(..),
                    defaultSettings,
                    setComplete,
                    -- * User preferences
                    Prefs(),
                    readPrefs,
                    defaultPrefs,
                    -- * Ctrl-C handling
                    -- $ctrlc
                    Interrupt(..),
                    withInterrupt,
                    handleInterrupt,
                    module System.Console.Haskeline.Completion,
                    module System.Console.Haskeline.MonadException)
                     where

import System.Console.Haskeline.LineState
import System.Console.Haskeline.Command
import System.Console.Haskeline.Command.History
import System.Console.Haskeline.Vi
import System.Console.Haskeline.Emacs
import System.Console.Haskeline.Prefs
import System.Console.Haskeline.Monads
import System.Console.Haskeline.MonadException
import System.Console.Haskeline.InputT
import System.Console.Haskeline.Completion
import System.Console.Haskeline.Term
import System.Console.Haskeline.Key

import System.IO
import qualified System.IO.UTF8 as UTF8
import Data.Char (isSpace)
import Control.Monad
import Data.Char(isPrint)




-- | A useful default.  In particular:
--
-- @
-- defaultSettings = Settings {
--           complete = completeFilename,
--           historyFile = Nothing,
--           }
-- @
defaultSettings :: MonadIO m => Settings m
defaultSettings = Settings {complete = completeFilename,
                        historyFile = Nothing}

-- | Write a string to the standard output.  Allows cross-platform display of Unicode
-- characters.
outputStr :: MonadIO m => String -> InputT m ()
outputStr xs = do
    putter <- asks putStrOut
    liftIO $ putter xs

-- | Write a string to the standard output, followed by a newline.  Allows
-- cross-platform display of Unicode characters.
outputStrLn :: MonadIO m => String -> InputT m ()
outputStrLn xs = outputStr (xs++"\n")

{- | Read one line of input.  The final newline (if any) is removed.

If 'stdin' is connected to a terminal with echoing enabled, 'getInputLine' provides a rich line-editing
user interface.  It returns 'Nothing' if the user presses @Ctrl-D@ when the input
text is empty.  All user interaction, including display of the input prompt, will occur
on the user's output terminal (which may differ from 'stdout').

If 'stdin' is not connected to a terminal, 'getInputLine' prints the prompt to 'stdout'
and reads one line of input. It returns 'Nothing'  if an @EOF@ is
encountered before any characters are read.
-}
getInputLine :: forall m . MonadException m => String -- ^ The input prompt
                            -> InputT m (Maybe String)
getInputLine prefix = do
    -- If other parts of the program have written text, make sure that it 
    -- appears before we interact with the user on the terminal.
    liftIO $ hFlush stdout
    rterm <- ask
    echo <- liftIO $ hGetEcho stdin
    case termOps rterm of
        Just tops | echo -> getInputCmdLine tops prefix
        _ -> simpleFileLoop prefix rterm

getInputCmdLine :: MonadException m => TermOps -> String -> InputT m (Maybe String)
getInputCmdLine tops prefix = do
    -- Load the necessary settings/prefs
    -- TODO: Cache the actions
    emode <- asks (\prefs -> case editMode prefs of
                    Vi -> viActions
                    Emacs -> emacsCommands)
    -- Run the main event processing loop
    result <- runInputCmdT tops $ runTerm tops
                    $ \getEvent -> do
                            let ls = emptyIM
                            drawLine prefix ls 
                            repeatTillFinish tops getEvent prefix ls emode
    -- Add the line to the history if it's nonempty.
    case result of 
        Just line | not (all isSpace line) -> addHistory line
        _ -> return ()
    return result

repeatTillFinish :: forall m s d 
    . (MonadTrans d, Term (d m), LineState s, MonadReader Prefs m)
            => TermOps -> d m Event -> String -> s -> KeyMap m s 
            -> d m (Maybe String)
repeatTillFinish tops getEvent prefix = loop
    where 
        loop :: forall t . LineState t => t -> KeyMap m t -> d m (Maybe String)
        loop s processor = do
                event <- handle (\(e::SomeException) -> movePast prefix s >> throwIO e) getEvent
                case event of
                    WindowResize -> withReposition tops prefix s $ loop s processor
                    KeyInput k -> do
                      action <- lift $ lookupKey processor k
                      case action of
                        Nothing -> actBell >> loop s processor
                        Just g -> case g s of
                            Left r -> movePast prefix s >> return r
                            Right f -> do
                                        KeyAction effect next <- lift f
                                        drawEffect prefix s effect
                                        loop (effectState effect) next

simpleFileLoop :: MonadIO m => String -> RunTerm -> m (Maybe String)
simpleFileLoop prefix rterm = liftIO $ do
    putStrOut rterm prefix
    atEOF <- hIsEOF stdin
    if atEOF
        then return Nothing
        else liftM Just UTF8.getLine

drawEffect :: (LineState s, LineState t, Term (d m), 
                MonadTrans d, MonadReader Prefs m) 
    => String -> s -> Effect t -> d m ()
drawEffect prefix s (Redraw shouldClear t) = if shouldClear
    then clearLayout >> drawLine prefix t
    else clearLine prefix s >> drawLine prefix t
drawEffect prefix s (Change t) = drawLineStateDiff prefix s t
drawEffect prefix s (PrintLines ls t) = do
    if isTemporary s
        then clearLine prefix s
        else movePast prefix s
    printLines ls
    drawLine prefix t
drawEffect prefix s (RingBell t) = drawLineStateDiff prefix s t >> actBell

drawLine :: (LineState s, Term m) => String -> s -> m ()
drawLine prefix s = drawLineStateDiff prefix Cleared s

drawLineStateDiff :: (LineState s, LineState t, Term m) 
                        => String -> s -> t -> m ()
drawLineStateDiff prefix s t = drawLineDiff (lineChars prefix s) 
                                        (lineChars prefix t)

clearLine :: (LineState s, Term m) => String -> s -> m ()
clearLine prefix s = drawLineStateDiff prefix s Cleared
        
actBell :: (Term (d m), MonadTrans d, MonadReader Prefs m) => d m ()
actBell = do
    style <- lift (asks bellStyle)
    case style of
        NoBell -> return ()
        VisualBell -> ringBell False
        AudibleBell -> ringBell True

movePast :: (LineState s, Term m) => String -> s -> m ()
movePast prefix s = moveToNextLine (lineChars prefix s)

withReposition :: (LineState s, Term m) => TermOps -> String -> s -> m a -> m a
withReposition tops prefix s f = do
    oldLayout <- ask
    newLayout <- liftIO $ getLayout tops
    if oldLayout == newLayout
        then f
        else local newLayout $ do
                reposition oldLayout (lineChars prefix s)
                f
----------

{- | Read one character of input from the user, without waiting for a newline.

If 'stdin' is connected to a terminal with echoing enabled, 'getInputLine' returns
'Nothing' if the user presses @Ctrl-D@.  All user interaction, incuding display of the
input prompt, will occur on the user's output terminal (which may differ from 'stdout').

If 'stdin' is not connected to a terminal, 'getInputChar' prints the prompt to 'stdout'
and reads one character of input. It returns 'Nothing'  if an @EOF@ is
encountered before any characters are read.

-}

getInputChar :: MonadException m => String -- ^ The input prompt
                    -> InputT m (Maybe Char)
getInputChar prefix = do
    liftIO $ hFlush stdout
    rterm <- ask
    echo <- liftIO $ hGetEcho stdin
    case termOps rterm of
        Just tops | echo -> getInputCmdChar tops prefix
        _ -> simpleFileChar prefix rterm

simpleFileChar :: MonadIO m => String -> RunTerm -> m (Maybe Char)
simpleFileChar prefix rterm = liftIO $ do
    putStrOut rterm prefix
    atEOF <- hIsEOF stdin
    if atEOF
        then return Nothing
        else liftM Just getChar -- TODO: utf8?

-- TODO: it might be possible to unify this function with getInputCmdLine,
-- maybe by calling repeatTillFinish here...
-- It shouldn't be too hard to make Commands parametrized over a return
-- value (which would be Maybe Char in this case).
-- My primary obstacle is that there's currently no way to have a
-- single character input cause a character to be printed and then
-- immediately exit without waiting for Return to be pressed.
getInputCmdChar :: MonadException m => TermOps -> String -> InputT m (Maybe Char)
getInputCmdChar tops prefix = runInputCmdT tops $ runTerm tops $ \getEvent -> do
                                                drawLine prefix emptyIM
                                                loop getEvent
    where
        s = emptyIM
        loop :: Term m => m Event -> m (Maybe Char)
        loop getEvent = do
            event <- handle (\(e::SomeException) -> movePast prefix emptyIM >> throwIO e) getEvent
            case event of
                KeyInput (Key m (KeyChar c))
                    | m /= noModifier -> loop getEvent
                    | c == '\EOT'     -> movePast prefix s >> return Nothing
                    | isPrint c -> do
                            let s' = insertChar c s
                            drawLineStateDiff prefix s s'
                            movePast prefix s'
                            return (Just c)
                WindowResize -> withReposition tops prefix emptyIM $ loop getEvent
                _ -> loop getEvent


------------
-- Interrupt

{- $ctrlc
The following functions provide portable handling of Ctrl-C events.  

These functions are not necessary on GHC version 6.10 or later, which
processes Ctrl-C events as exceptions by default.
-}

-- | If Ctrl-C is pressed during the given computation, throw an exception of type 
-- 'Interrupt'.
withInterrupt :: MonadException m => InputT m a -> InputT m a
withInterrupt f = do
    rterm <- ask
    wrapInterrupt rterm f

-- | Catch and handle an exception of type 'Interrupt'.
handleInterrupt :: MonadException m => m a 
                        -- ^ Handler to run if Ctrl-C is pressed
                     -> m a -- ^ Computation to run
                     -> m a
handleInterrupt f = handleDyn $ \Interrupt -> f



