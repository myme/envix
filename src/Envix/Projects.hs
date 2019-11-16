module Envix.Projects
  ( Project (..)
  , Command
  , find_in_project
  , find_projects
  , find_projects_by_name
  , find_project_commands
  , implode_home
  , mkproject
  , project_exec
  , project_path
  , resolve_command
  , sort_projects
  ) where

import qualified Control.Foldl as Fold
import           Control.Monad (filterM)
import           Data.Function (on)
import           Data.List (find, sortBy)
import           Data.Text (isInfixOf)
import qualified Data.Text as T
import           Envix.Config as Config
import           Envix.Nix
import           Envix.Options as Options hiding (select)
import           Envix.Projects.Types as Types
import           Envix.Select
import           Prelude hiding (FilePath)
import           System.Wordexp
import           Turtle hiding (find, select, sort, sortBy, toText)

mkproject :: FilePath -> Project
mkproject path' = Project (filename path') (parent path') []

-- | Replace the value of $HOME in a path with "~"
implode_home :: FilePath -> IO FilePath
implode_home path' = do
  home' <- home
  pure $ case stripPrefix (home' </> "") path' of
    Nothing -> path'
    Just rest -> "~" </> rest

-- | Find/filter out a project in which path is a subdirectory.
find_in_project :: [Project] -> FilePath -> Maybe Project
find_in_project projects path' = find (is_prefix . project_path) projects
  where is_prefix project = (T.isPrefixOf `on` format fp) project path'

find_projects_by_name :: FilePath -> Config -> IO [Project]
find_projects_by_name project = fmap find_matching . find_projects
  where find_matching = filter ((project `isInfix`) . toText . project_name)
        isInfix p = isInfixOf (toText p)
        toText = format fp

find_projects :: Config -> IO [Project]
find_projects config = reduce Fold.list $ do
  expanded <- liftIO $ traverse expand_path (Options.source_dirs $ Config.options config)
  candidate <- cat $ map ls (concat expanded)
  types <- liftIO (find_project_types candidate (Config.project_types config))
  if null types
    then mzero
    else pure Project { Types.project_name = filename candidate
                      , Types.project_dir = parent candidate
                      , Types.project_types = types
                      }

find_project_commands :: Project -> [Command]
find_project_commands project = concatMap project_commands (Types.project_types project)

expand_path :: FilePath -> IO [FilePath]
expand_path path' = do
  expanded <- wordexp nosubst (encodeString path')
  pure $ either (const []) (map fromString) expanded

sort_projects :: [Project] -> [Project]
sort_projects = sortBy (compare `on` project_name)

project_exec :: (Project -> IO ()) -- ^ Non-nix project action
             -> (FilePath -> IO ()) -- ^ Nix project action
             -> Bool -- ^ Use nix
             -> Project -> IO ()
project_exec plain with_nix use_nix project =
  let action = if use_nix
        then find_nix_file (project_path project)
        else pure Nothing
  in action >>= \case
    Nothing -> plain project
    Just nix_file -> with_nix nix_file

-- | Given a path, find matching markers/project type.
find_project_types :: FilePath -> [ProjectType] -> IO [ProjectType]
find_project_types path' project_types = do
  is_dir <- isDirectory <$> stat path'
  if not is_dir
    then pure []
    else filterM has_markers project_types
  where has_markers = fmap and . traverse (`test_marker` path') . project_markers

-- | Test that a marker is valid for a path
test_marker :: ProjectMarker -> FilePath -> IO Bool
test_marker (ProjectPath marker) p = testpath (p </> marker)
test_marker (ProjectFile marker) p = testfile (p </> marker)
test_marker (ProjectDir  marker) p = testdir (p </> marker)
test_marker (ProjectFunc marker) p = marker p

-- | Interpolate all command parts into a single text value.
resolve_command :: Project -> Command -> Select Text
resolve_command project (Command parts _) = T.intercalate " " <$> mapM interpolate parts
  where interpolate (TextPart t) = pure t
        interpolate PathPart = pure $ format fp $ project_path project
        interpolate FilePart = do
          selection <- select (pushd (project_path project) >> inshell "git ls-files" mempty)
          case selection of
            Selection _ t -> pure t
            _ -> pure ""
