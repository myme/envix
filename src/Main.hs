module Main where

import           Data.Bool (bool)
import           Data.Maybe (fromMaybe)
import qualified Data.Text.IO as T
import qualified Envix.Config as Opts
import           Envix.Fzf
import           Envix.Process
import           Envix.Projects
import           Envix.Rofi hiding (d, s)
import           Prelude hiding (FilePath)
import qualified System.IO as IO
import           Turtle hiding (decimal, find, sort, sortBy)

-- | List projects, filtering if a filter is specified.
list :: Maybe FilePath -> [Project] -> IO ()
list project projects = do
  paths <- fmap (format fp . project_path) <$> traverse implode_home projects
  let fzf_opts = fzf_filter $ maybe "" (format fp) project
  fzf fzf_opts paths >>= \case
    FzfDefault matching -> T.putStr matching
    _ -> T.hPutStrLn IO.stderr "No projects."

-- | Find/filter out a project and perform an action
projectAction :: Commands -> [Project] -> Opts.Options -> IO ()
projectAction commands projects opts = do
  def_backend <- bool Opts.Rofi Opts.Fzf <$> IO.hIsTerminalDevice IO.stdin
  let backend = fromMaybe def_backend (Opts.backend opts)
      (find, exec) = case backend of
        Opts.Fzf -> (fzf_projects, fzf_exec)
        Opts.Rofi -> (rofi_projects, rofi_exec)
  action <- find (format fp <$> Opts.project opts) commands projects
  case action of
    Nothing -> do
      T.hPutStrLn IO.stderr "No project selected."
      exit (ExitFailure 1)
    Just (project, command) -> if Opts.select opts
      then printf (fp % "\n") (project_path project)
      else exec (Opts.command opts <|> command) (Opts.no_nix opts) project

-- TODO: Integrate with `direnv`
-- TODO: Launch terminal with nix-shell output if taking a long time.
-- If switching to a project takes a long time it would be nice to see a window
-- showing the progress of starting the environment.
main :: IO ()
main = do
  opts <- Opts.parse_args
  let source_dirs = Opts.source_dirs opts
      -- TODO: Allow changing default command
      -- TODO: Allow format strings (%s) in commands to insert e.g. project path
      -- TODO: Project local commands (project/path/.envix)
      commands = [("konsole", "Terminal")
                 ,("emacs", "Editor")
                 ,("dolphin", "Files")
                 ]

  projects <- sort_projects <$> find_projects source_dirs

  if Opts.list opts
    then list (Opts.project opts) projects
    else projectAction commands projects opts
