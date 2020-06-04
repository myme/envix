module Nixon.Config.Types
  ( Backend(..)
  , LogLevel(..)
  , Config(..)
  ) where

import Nixon.Project.Types
import Prelude hiding (FilePath)
import Turtle (FilePath)

data Backend = Fzf | Rofi deriving Show

data LogLevel = LogDebug | LogInfo | LogWarning | LogError
  deriving (Eq, Ord, Show)

data Config = Config { backend :: Maybe Backend
                     , exact_match :: Maybe Bool
                     , project_types :: [ProjectType]
                     , source_dirs :: [FilePath]
                     , use_direnv :: Maybe Bool
                     , use_nix :: Maybe Bool
                     , loglevel :: LogLevel
                     }
