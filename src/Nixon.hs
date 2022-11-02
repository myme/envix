module Nixon
  ( nixon,
    nixonWithConfig,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (throwIO, try)
import Control.Monad (foldM)
import Control.Monad.Catch (MonadMask)
import Control.Monad.Trans.Maybe (MaybeT (..))
import Control.Monad.Trans.Reader (ask, local)
import Data.Aeson (eitherDecodeStrict)
import Data.Foldable (find)
import Data.List (intersect)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Nixon.Backend (Backend)
import qualified Nixon.Backend as Backend
import Nixon.Backend.Fzf
  ( fzf,
    fzfBackend,
    fzfFilter,
  )
import Nixon.Backend.Rofi (rofiBackend)
import Nixon.Command (Command (..), CommandEnv (..), CommandOutput (..), show_command, show_command_with_description)
import qualified Nixon.Command as Cmd
import qualified Nixon.Config as Config
import Nixon.Config.Options (BackendType (..), CompletionType, ProjectOpts (..), RunOpts (..), SubCommand (..))
import qualified Nixon.Config.Options as Opts
import qualified Nixon.Config.Types as Config
import Nixon.Evaluator (evaluate, getEvaluator)
import Nixon.Logging (log_error, log_info)
import Nixon.Process (Env, run, run_with_output)
import Nixon.Project (Project, ProjectType (..), project_path)
import qualified Nixon.Project as P
import Nixon.Select (Candidate (..), Selection (..), Selector, selector_multiple)
import qualified Nixon.Select as Select
import Nixon.Types
  ( Config (commands, project_dirs, project_types),
    Env (backend, config),
    Nixon,
    NixonError (EmptyError, NixonError),
    runNixon,
  )
import Nixon.Utils (implode_home, toLines)
import System.Console.Haskeline (defaultSettings, getInputLineWithInitial, runInputT)
import System.Environment (withArgs)
import Turtle
  ( Alternative (empty),
    ExitCode (ExitFailure),
    FilePath,
    MonadIO (..),
    Shell,
    Text,
    cd,
    d,
    exit,
    format,
    fp,
    lineToText,
    need,
    printf,
    pwd,
    s,
    select,
    stream,
    w,
    (%),
  )
import qualified Turtle.Bytes as BS
import Prelude hiding (FilePath, fail, log)

-- | List projects, filtering if a query is specified.
listProjects :: [Project] -> Maybe Text -> Nixon ()
listProjects projects query = do
  let fmt_line = fmap (Select.Identity . format fp)
  paths <- liftIO $ fmt_line <$> traverse (implode_home . project_path) projects
  let fzf_opts = fzfFilter $ fromMaybe "" query
  liftIO (fzf fzf_opts (Turtle.select paths)) >>= \case
    Selection _ matching -> liftIO $ T.putStr (T.unlines matching)
    _ -> log_error "No projects."

-- | List commands for a project, filtering if a query is specified
listProjectCommands :: Project -> Maybe Text -> Nixon ()
listProjectCommands project query = do
  commands <- map show_command_with_description <$> findProjectCommands project
  let fzfOpts = fzfFilter $ fromMaybe "" query
  selection <- fzf fzfOpts (Turtle.select $ Identity <$> commands)
  case selection of
    Selection _ matching -> liftIO $ T.putStr (T.unlines matching)
    _ -> log_error "No commands."

fail :: MonadIO m => NixonError -> m a
fail err = liftIO (throwIO err)

-- | Attempt to parse a local JSON
withLocalConfig :: FilePath -> Nixon a -> Nixon a
withLocalConfig filepath action = do
  liftIO (Config.find_local_config filepath) >>= \case
    Nothing -> action
    Just cfg -> local (\env -> env {config = config env <> cfg}) action

findProjectCommands :: Project -> Nixon [Command]
findProjectCommands project = filter filter_cmd . commands . config <$> ask
  where
    ptypes = map project_id $ P.project_types project
    filter_cmd cmd =
      let ctypes = cmdProjectTypes cmd
       in null ctypes || not (null $ intersect ptypes ctypes)

-- | Find and handle a command in a project.
findAndHandleCmd :: Project -> RunOpts -> Nixon ()
findAndHandleCmd project opts = withLocalConfig (project_path project) $ do
  find_command <- Backend.commandSelector <$> getBackend
  cmds <- filter (not . Cmd.cmdIsHidden) <$> findProjectCommands project
  cmd <- liftIO $ find_command project (Opts.run_command opts) cmds
  handleCmd project cmd opts

-- | Find and run a command in a project.
handleCmd :: Project -> Selection Command -> RunOpts -> Nixon ()
handleCmd project cmd opts = do
  selector <- Backend.selector <$> getBackend
  case cmd of
    EmptySelection -> fail $ EmptyError "No command selected."
    CanceledSelection -> fail $ EmptyError "Command selection canceled."
    Selection _ [] -> fail $ EmptyError "No command selected."
    Selection selectionType [cmd'] ->
      if Opts.run_select opts
        then do
          resolved <- resolveCmd project selector cmd' Select.defaults
          printf (s % "\n") (T.unlines resolved)
        else do
          case selectionType of
            Select.Default -> runCmd project cmd' (Opts.run_args opts)
            Select.Edit -> editCmd project cmd' (Opts.run_args opts)
            Select.Show -> showCmd cmd'
            Select.Visit -> visitCmd cmd'
    Selection _ _ -> fail $ NixonError "Multiple commands selected."

-- | Actually run a command
-- TODO: Replace Project with FilePath (project_path project)
runCmd :: Project -> Command -> [Text] -> Nixon ()
runCmd project cmd args = do
  selector <- Backend.selector <$> getBackend
  let project_selector select_opts shell' =
        cd (project_path project)
          >> selector (select_opts <> Select.title (show_command cmd)) shell'
  (stdin, args', env') <- resolveEnv project project_selector cmd args
  evaluate cmd args' (Just $ project_path project) env' (toLines <$> stdin)

-- | Edit the command source before execution
editCmd :: Project -> Command -> [Text] -> Nixon ()
editCmd project cmd args = do
  edited <- editSelection (T.strip $ Cmd.cmdSource cmd)
  case edited of
    Nothing -> fail $ EmptyError "Empty command."
    Just source -> runCmd project (cmd {Cmd.cmdSource = source}) args

-- | Print the command
showCmd :: Command -> Nixon ()
showCmd = liftIO . T.putStrLn . Cmd.cmdSource

-- | "Visit" the command where it's defined
visitCmd :: Command -> Nixon ()
visitCmd cmd =
  case Cmd.cmdLocation cmd of
    Nothing -> fail $ NixonError "Unable to find command location."
    Just loc -> do
      let args =
            [ format ("+" % d) $ Cmd.cmdLineNr loc,
              format fp $ Cmd.cmdFilePath loc
            ]
      editor <-
        fromMaybe "nano"
          <$> runMaybeT
            ( MaybeT (need "VISUAL") <|> MaybeT (need "EDITOR")
            )
      run (editor :| args) Nothing [] empty

-- | Resolve all command placeholders to either stdin input, positional arguments or env vars.
resolveEnv :: Project -> Selector Nixon -> Command -> [Text] -> Nixon (Maybe (Shell Text), [Text], Nixon.Process.Env)
resolveEnv project selector cmd args = do
  let mappedArgs = zip (cmdEnv cmd) (map Select.search args <> repeat Select.defaults)
  (stdin, args', envs) <- foldM resolveEach (Nothing, [], []) mappedArgs
  pure (stdin, args', nixonEnvs ++ envs)
  where
    nixonEnvs = [("nixon_project_path", format fp $ project_path project)]

    resolveEach (stdin, args', envs) ((name, Env envType cmdName multiple), select_opts) = do
      cmd' <- assertCommand cmdName
      let select_opts' = select_opts {selector_multiple = Just multiple}
      resolved <- resolveCmd project selector cmd' select_opts'
      pure $ case envType of
        -- Standard inputs are concatenated
        Cmd.Stdin ->
          let stdinCombined = Just $ case stdin of
                Nothing -> select resolved
                Just prev -> prev <|> select resolved
          in (stdinCombined, args', envs)
        -- Each line counts as one positional argument
        Cmd.Arg -> (stdin, args' <> resolved, envs)
        -- Environment variables are concatenated into space-separated line
        Cmd.EnvVar -> (stdin, args', envs <> [(name, T.unwords resolved)])

    assertCommand cmd_name = do
      cmd' <- find ((==) cmd_name . cmdName) . commands . config <$> ask
      maybe (error $ "Invalid argument: " <> T.unpack cmd_name) pure cmd'

-- | Resolve command to selectable output.
resolveCmd :: Project -> Selector Nixon -> Command -> Select.SelectorOpts -> Nixon [Text]
resolveCmd project selector cmd select_opts = do
  (stdin, args, env') <- resolveEnv project selector cmd []
  let path' = Just $ project_path project
  linesEval <- getEvaluator (run_with_output stream) cmd args path' env' (toLines <$> stdin)
  jsonEval <- getEvaluator (run_with_output BS.stream) cmd args path' env' (BS.fromUTF8 <$> stdin)
  selection <- selector select_opts $ do
    case cmdOutput cmd of
      Lines -> Select.Identity . lineToText <$> linesEval
      JSON -> do
        output <- BS.strict jsonEval
        case eitherDecodeStrict output :: Either String [Select.Candidate] of
          Left err -> error err
          Right candidates -> Turtle.select candidates
  case selection of
    Selection _ result -> pure result
    _ -> error "Argument expansion aborted"

getBackend :: Nixon Backend
getBackend = do
  env <- ask
  let cfg = config env
  pure $ case backend env of
    Fzf -> fzfBackend cfg
    Rofi -> rofiBackend cfg

-- | Use readline to manipulate/change a fzf selection
editSelection :: (MonadIO m, MonadMask m) => Text -> m (Maybe Text)
editSelection selection = runInputT defaultSettings $ do
  line <- getInputLineWithInitial "> " (T.unpack selection, "")
  pure $ case line of
    Just "" -> Nothing
    line' -> T.pack <$> line'

-- | Find/filter out a project and perform an action.
projectAction :: [Project] -> ProjectOpts -> Nixon ()
projectAction projects opts
  | Opts.proj_list opts = listProjects projects (Opts.proj_project opts)
  | otherwise = do
    ptypes <- project_types . config <$> ask
    projectSelector <- Backend.projectSelector <$> getBackend

    let findProject (Just ".") = do
          inProject <- P.find_in_project ptypes =<< pwd
          case inProject of
            Nothing -> projectSelector Nothing projects
            Just project -> pure $ Selection Select.Default [project]
        findProject query = projectSelector query projects

    selection <- liftIO $ findProject (Opts.proj_project opts)
    case selection of
      EmptySelection -> liftIO (throwIO $ EmptyError "No project selected.")
      CanceledSelection -> liftIO (throwIO $ EmptyError "Project selection canceled.")
      Selection _selectionType [project] ->
        if Opts.proj_select opts
          then liftIO $ printf (fp % "\n") (project_path project)
          else
            let opts' = RunOpts (Opts.proj_command opts) (Opts.proj_args opts) (Opts.proj_list opts) (Opts.proj_select opts)
             in findAndHandleCmd project opts'
      Selection _ _ -> liftIO (throwIO $ NixonError "Multiple projects selected.")

-- | Run a command from current directory
runAction :: RunOpts -> Nixon ()
runAction opts = do
  ptypes <- project_types . config <$> ask
  project <- liftIO (P.find_in_project_or_default ptypes =<< pwd)
  if Opts.run_list opts
    then listProjectCommands project (Opts.run_command opts)
    else findAndHandleCmd project opts

die :: (Show a, MonadIO m) => a -> m b
die err = liftIO $ log_error (format w err) >> exit (ExitFailure 1)

-- If switching to a project takes a long time it would be nice to see a window
-- showing the progress of starting the environment.
nixonWithConfig :: MonadIO m => Config.Config -> m ()
nixonWithConfig userConfig = liftIO $ do
  (sub_cmd, cfg) <- either die pure =<< Opts.parse_args (nixonCompleter userConfig)
  err <- try $
    runNixon (userConfig <> cfg) $ case sub_cmd of
      ProjectCommand projectOpts -> do
        log_info "Running <project> command"
        cfg' <- config <$> ask
        let ptypes = project_types cfg'
            srcs = project_dirs cfg'
        projects <- P.sort_projects <$> liftIO (P.find_projects 1 ptypes srcs)
        projectAction projects projectOpts
      RunCommand runOpts -> do
        log_info "Running <run> command"
        runAction runOpts
  case err of
    Left (EmptyError msg) -> die msg
    Left (NixonError msg) -> die msg
    Right _ -> pure ()

nixonCompleter :: MonadIO m => Config.Config -> CompletionType -> [String] -> m [String]
nixonCompleter userConfig compType args = do
  let parse_args = Opts.parse_args $ nixonCompleter userConfig
  (_, cfg) <- liftIO $ either die pure =<< withArgs args parse_args
  liftIO $
    runNixon (userConfig <> cfg) $ do
      cfg' <- config <$> ask
      let ptypes = project_types cfg'
          srcs = project_dirs cfg'
      projects <- P.sort_projects <$> liftIO (P.find_projects 1 ptypes srcs)
      case compType of
        Opts.Project -> pure $ map (T.unpack . format fp . P.project_name) projects
        Opts.Run -> do
          project <- case args of
            ("project" : p : _) -> do
              current <- P.from_path <$> pwd
              let p' = find ((==) p . T.unpack . format fp . P.project_name) projects
              pure $ fromMaybe current p'
            _ -> liftIO $ P.find_in_project_or_default ptypes =<< pwd
          commands <- withLocalConfig (project_path project) $ findProjectCommands project
          pure $ map (T.unpack . cmdName) commands

-- | Nixon with default configuration
nixon :: MonadIO m => m ()
nixon = nixonWithConfig Config.defaultConfig
