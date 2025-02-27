module Nixon.Logging
  ( LogLevel (..),
    HasLogging (..),
    log,
    log_debug,
    log_error,
    log_info,
    log_warn,
  )
where

import Control.Monad (when)
import Nixon.Prelude
import Nixon.Utils (printErr)

data LogLevel = LogDebug | LogInfo | LogWarning | LogError
  deriving (Eq, Ord, Show, Bounded, Enum)

class (Monad m) => HasLogging m where
  loglevel :: m LogLevel
  logout :: Text -> m ()

instance HasLogging IO where
  loglevel = return LogInfo
  logout = printErr

log :: (HasLogging m) => LogLevel -> Text -> m ()
log level msg = do
  should_log <- (level >=) <$> loglevel
  when should_log $ logout msg

log_debug :: (HasLogging m) => Text -> m ()
log_debug = log LogDebug

log_info :: (HasLogging m) => Text -> m ()
log_info = log LogInfo

log_warn :: (HasLogging m) => Text -> m ()
log_warn = log LogWarning

log_error :: (HasLogging m) => Text -> m ()
log_error = log LogError
