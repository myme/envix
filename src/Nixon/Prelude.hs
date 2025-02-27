-- | Custom Prelude
module Nixon.Prelude
  ( -- * "Prelude"
    module Prelude,

    -- * "Applicatives"
    module Applicative,

    -- * "Monads"
    module Monads,

    -- * "Text"
    module Text,
    FilePath,
  )
where

import Control.Applicative as Applicative (Alternative ((<|>)))
import Control.Monad as Monads ((<=<), (>=>))
import Control.Monad.IO.Class as Monads (MonadIO (..), liftIO)
import Data.Text as Text (Text)
import Turtle (FilePath)
import Prelude hiding (FilePath, fail, log)
