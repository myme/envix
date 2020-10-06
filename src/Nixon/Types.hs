{-# LANGUAGE FlexibleInstances #-}

module Nixon.Types
  ( Env(..)
  , Nixon
  , NixonError(..)
  , Config.Config(commands, exact_match, project_types, source_dirs, terminal, use_direnv, use_nix)
  , ask
  , runNixon
  ) where

import           Control.Exception
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader
import           Data.Bool (bool)
import           Data.Maybe (fromMaybe)
import           Nixon.Config.Types (Backend(..), Config)
import qualified Nixon.Config.Types as Config
import           Nixon.Logging (HasLogging)
import qualified Nixon.Logging as Logging
import           Nixon.Utils
import           Prelude hiding (FilePath)
import qualified System.IO as IO
import           Turtle hiding (env)

data Env = Env
  { backend :: Backend
  , config :: Config
  }

newtype NixonError = EmptyError Text deriving Show

instance Exception NixonError

get_backend :: MonadIO m => Maybe Backend -> m Backend
get_backend backend = do
  def_backend <- liftIO $ bool Rofi Fzf <$> IO.hIsTerminalDevice IO.stdin
  pure $ fromMaybe def_backend backend

-- | Merge the mess of CLI args, config file + user overrides (custom build)
build_env :: MonadIO m => Config -> m Env
build_env config = do
  backend <- get_backend (Config.backend config)
  pure Env { backend, config = config }

type Nixon = ReaderT Env IO

instance HasLogging Nixon where
  loglevel = fromMaybe Logging.LogWarning . Config.loglevel . config <$> ask
  logout = printErr

runNixon :: MonadIO m => Config -> ReaderT Env m a -> m a
runNixon config action = do
  env <- liftIO (build_env config)
  runReaderT action env
