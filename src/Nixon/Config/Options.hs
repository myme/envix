module Nixon.Config.Options
  ( Backend(..)
  , LogLevel(..)
  , Options(..)
  , SubCommand(..)
  , BuildOpts(..)
  , ProjectOpts(..)
  , default_options
  , merge_opts
  , parse_args
  ) where

import           Data.Maybe (fromMaybe)
import           Data.Text (Text)
import qualified Data.Text as Text
import           Nixon.Config.JSON (JSONError(..))
import qualified Nixon.Config.JSON as JSON
import           Nixon.Config.Types hiding (Config(..))
import           Prelude hiding (FilePath)
import qualified Options.Applicative as Opts
import           Turtle hiding (err, select)

-- TODO: Add CLI opt for outputting bash/zsh completion script.
--       https://github.com/pcapriotti/optparse-applicative#bash-zsh-and-fish-completions
-- TODO: Add support for independent directory/tree of nix files.
--       The idea is that for some projects you don't want to "pollute" the
--       project by adding e.g. nix files. Add support so that "nixon" can find
--       these files and launch the appropriate environment without the files
--       having to be *in* the project root.
-- TODO: Add "Backend" configuration support (for e.g. styles like height)
-- E.g. --backend-arg "fzf: --height 40"
--      --backend-arg "rofi: ..."
-- | Command line options.
data Options = Options
  { backend :: Maybe Backend
    -- , backend_args :: [Text]
  , exact_match :: Maybe Bool
  , source_dirs :: [FilePath]
  , use_direnv :: Maybe Bool
  , use_nix :: Maybe Bool
  , loglevel :: Maybe LogLevel
  , config :: Maybe FilePath
  , sub_command :: SubCommand
  } deriving Show

data SubCommand = BuildCommand BuildOpts
                | ProjectCommand ProjectOpts
                | RunCommand ProjectOpts
                deriving Show

data BuildOpts = BuildOpts
  { infile :: FilePath
  , outfile :: FilePath
  } deriving Show

data ProjectOpts = ProjectOpts
  { project :: Maybe Text
  , command :: Maybe Text
  , list :: Bool
  , select :: Bool
  } deriving Show

default_options :: Options
default_options = Options
  { backend = Nothing
  , exact_match = Nothing
  , source_dirs = []
  , use_direnv = Nothing
  , use_nix = Nothing
  , loglevel = Just LogWarning
  , config = Nothing
  , sub_command = ProjectCommand ProjectOpts
    { project = Nothing
    , command = Nothing
    , list = False
    , select = False
    }
  }

-- | Add options supporting negation with a "no-" prefix.
maybeSwitch :: Text -> Char -> Text -> Parser (Maybe Bool)
maybeSwitch long short help = Opts.flag Nothing (Just True) (
                                  Opts.short short <>
                                  Opts.long (Text.unpack long) <>
                                  Opts.help (Text.unpack help)) <|>
                              Opts.flag Nothing (Just False) (
                                  Opts.long ("no-" ++ Text.unpack long))

-- TODO: Allow switching off "use_direnv" and "use_nix"
parser :: Parser Options
parser = Options
  <$> optional (opt parse_backend "backend" 'b' "Backend to use: fzf, rofi")
  <*> maybeSwitch "exact" 'e' "Enable exact match"
  <*> many (optPath "path" 'p' "Project directory")
  <*> maybeSwitch "direnv" 'd' "Evaluate .envrc files using `direnv exec`"
  <*> maybeSwitch "nix" 'n' "Invoke nix-shell if *.nix files are found"
  <*> optional (opt parse_loglevel "loglevel" 'l' "Loglevel: debug, info, warning, error")
  <*> optional (optPath "config" 'C' "Path to configuration file (default: ~/.config/nixon)")
  <*> ( BuildCommand <$> subcommand "build" "Build custom nixon" build_parser <|>
        ProjectCommand <$> subcommand "project" "Project actions" project_parser <|>
        RunCommand <$> subcommand "run" "Run command" project_parser <|>
        ProjectCommand <$> project_parser)
  where
    parse_backend = flip lookup
      [("fzf", Fzf)
      ,("rofi", Rofi)
      ]
    parse_loglevel = flip lookup
      [("debug", LogDebug)
      ,("info", LogInfo)
      ,("warning", LogWarning)
      ,("warn", LogWarning)
      ,("error", LogError)
      ]

build_parser :: Parser BuildOpts
build_parser = BuildOpts
  <$> (fromMaybe "nixon.hs" <$> optional (argPath "infile" "Input file (default: nixon.hs)"))
  <*> (fromMaybe "nixon"    <$> optional (argPath "outfile" "Output file (default: nixon)"))

project_parser :: Parser ProjectOpts
project_parser = ProjectOpts
  <$> optional (argText "project" "Project to jump into")
  <*> optional (argText "command" "Command to run")
  <*> switch "list" 'l' "List projects"
  <*> switch "select" 's' "Select a project or command and output on stdout"

merge_opts :: ProjectOpts -> ProjectOpts -> ProjectOpts
merge_opts secondary primary = ProjectOpts
  { project = project primary <|> project secondary
  , command = command primary <|> command secondary
  , list = list primary
  , select = select primary
  }

-- | Read configuration from config file and command line arguments
parse_args :: IO (Either Text Options)
parse_args = do
  opts <- Turtle.options "Launch project environment" parser
  config_path <- maybe JSON.default_path pure (config opts)
  JSON.read_config config_path >>= \case
    Left NoSuchFile -> case config opts of
      Nothing -> pure $ Right opts
      Just p  -> pure $ Left (format ("No such file:"%fp) p)
    Left EmptyFile -> pure $ Right opts
    Left (ParseError err) -> pure $ Left err
    Right json -> pure $ Right opts
      { exact_match = exact_match opts <|> JSON.exact_match json
      , source_dirs = JSON.source_dirs json ++ source_dirs opts
      , use_direnv = use_direnv opts <|> JSON.use_direnv json
      , use_nix = use_nix opts <|> JSON.use_nix json
      }
