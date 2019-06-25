module Envix.Process
  ( arg
  , arg_fmt
  , flag
  , build_args
  ) where

import Data.Maybe (catMaybes)

flag :: a -> Bool -> Maybe [a]
flag key value = if value then Just [key] else Nothing

arg :: Applicative f => a -> a -> f [a]
arg key = pure . ([key] <>) . pure

arg_fmt :: Applicative f => b -> (a -> b) -> a -> f [b]
arg_fmt key f = pure . ([key] <>) . pure . f

build_args :: [Maybe [a]] -> [a]
build_args = concat . catMaybes