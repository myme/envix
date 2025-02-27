{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Nixon.Config.Markdown
  ( defaultPath,
    parseMarkdown,
    parseHeaderArgs,
    parseCommandArg,
    parseCommandName,
  )
where

import CMark (commonmarkToNode)
import qualified CMark as M
import Control.Monad (when)
import Control.Monad.Fail (fail)
import qualified Data.Aeson as Aeson
import Data.Bifunctor (Bifunctor (bimap, first))
import Data.Char (isSpace)
import Data.Either (partitionEithers)
import Data.Functor (($>))
import Data.List (find)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (pack, strip)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Yaml as Yaml
import Nixon.Command (bg, (<!))
import qualified Nixon.Command as Cmd
import qualified Nixon.Command.Placeholder as P
import qualified Nixon.Config.JSON as JSON
import Nixon.Config.Types
  ( Config
      ( bin_dirs,
        commands,
        exact_match,
        ignore_case,
        loglevel,
        project_dirs,
        project_types,
        use_direnv,
        use_nix
      ),
    defaultConfig,
  )
import qualified Nixon.Language as Lang
import Nixon.Prelude
import System.Directory (XdgDirectory (..), getXdgDirectory)
import qualified Text.Parsec as P
import Text.Parsec.Text (Parser)
import Text.Read (readMaybe)
import Turtle
  ( IsString (fromString),
    format,
    s,
    w,
    (%),
  )
import Turtle.Format (fp)

data PosInfo = PosInfo
  { posName :: FilePath,
    posLocation :: Maybe M.PosInfo,
    posHeaderLevel :: Int
  }

defaultPath :: (MonadIO m) => m FilePath
defaultPath = liftIO $ fromString <$> getXdgDirectory XdgConfig "nixon.md"

buildConfig :: (JSON.Config, [Cmd.Command]) -> Config
buildConfig (cfg, cmds) =
  defaultConfig
    { bin_dirs = JSON.bin_dirs cfg,
      exact_match = JSON.exact_match cfg,
      ignore_case = JSON.ignore_case cfg,
      project_dirs = JSON.project_dirs cfg,
      project_types = JSON.project_types cfg,
      use_direnv = JSON.use_direnv cfg,
      use_nix = JSON.use_nix cfg,
      commands = cmds,
      loglevel = Nothing
    }

parseMarkdown :: FilePath -> Text -> Either Text Config
parseMarkdown fileName markdown =
  buildConfig
    <$> parse fileName (extract (commonmarkToNode [] markdown))

extract :: M.Node -> [Node]
extract (M.Node pos nodeType children) = case nodeType of
  M.HEADING level ->
    let (name, args, kwargs) = parseHeaderArgs $ getText children
        (isCommand, isBg) = case find isCode children of
          Just (M.Node _ (M.CODE text) _) -> (True, "&" `T.isSuffixOf` T.strip text)
          _ -> (False, False)
        args' =
          ["bg" | isBg && "bg" `notElem` args]
            ++ ["command" | isCommand && "command" `notElem` args]
            ++ args
     in [Head pos level name (name, args', kwargs)]
  M.CODE_BLOCK info text ->
    let (lang, attrs) = parseInfo info
     in [Source lang attrs text]
  M.PARAGRAPH -> [Paragraph $ getText children]
  _ ->
    -- Go one beyond because we're subtracting 1
    let pos' = (\p -> p {M.startLine = M.endLine p + 1}) <$> pos
     in concatMap extract children <> [End pos']
  where
    isCode (M.Node _ (M.CODE _) _) = True
    isCode _ = False
    parseInfo info = case T.words info of
      (lang : attrs) -> (Lang.parseLang lang, attrs)
      attrs -> (Lang.None, attrs)

type Attrs =
  -- | name args kwargs
  (Text, [Text], [(Text, Text)])

parseHeaderArgs :: Text -> Attrs
parseHeaderArgs input = case P.parse parser "" input of
  Left _ -> (input, [], [])
  Right xs -> xs
  where
    parser :: Parser Attrs
    parser = do
      name <- T.strip . T.pack <$> P.many (P.noneOf ['{'])
      (args, kwargs) <- partitionEithers <$> braces (P.sepBy (parseArg <|> parseKwArg) P.spaces)
      pure (name, args, kwargs)
    parseArg = do
      name <- T.pack <$> (P.char '.' *> identifier)
      pure $ Left name
    parseKwArg = do
      name <- T.pack <$> identifier
      value <- T.pack <$> (P.char '=' *> (quotes letters <|> letters))
      pure $ Right (name, value)
    letters = P.many1 P.letter
    identifier = P.many1 (P.letter <|> P.char '_' <|> P.char '-')
    braces = P.between (P.char '{') (P.char '}')
    quotes = P.between (P.char '"') (P.char '"')

getText :: [M.Node] -> Text
getText [] = ""
getText (M.Node _ nodeType children : xs) = T.strip $ T.intercalate " " [nodeText, getText children, getText xs]
  where
    nodeText = case nodeType of
      M.TEXT txt -> txt
      M.HTML_BLOCK txt -> txt
      M.HTML_INLINE txt -> txt
      M.CODE txt -> txt
      M.CODE_BLOCK _ txt -> txt
      _ -> ""

type Pos = Maybe M.PosInfo

data Node
  = -- | level name command type
    Head Pos Int Text Attrs
  | -- | info src
    Source Lang.Language [Text] Text
  | Paragraph Text
  | End Pos
  deriving (Show)

data ParseState = S
  { stateHeaderLevel :: Int,
    stateProjectTypes :: [Text],
    stateLastPos :: PosInfo
  }

-- | Parse Command blocks from a list of nodes
parse :: FilePath -> [Node] -> Either Text (JSON.Config, [Cmd.Command])
parse fileName nodes = bimap (fromMaybe JSON.empty) reverse <$> go (S 0 [] initPos) (Nothing, []) nodes
  where
    initPos = PosInfo fileName Nothing 0
    go _ ps [] = Right ps
    go st (cfg, ps) (End pos : rest) =
      let posInfo = PosInfo fileName pos st.stateHeaderLevel
       in go st (cfg, addLocation st.stateLastPos posInfo ps) rest
    go st (cfg, ps) nodes'@(Head _ l _ _ : _)
      -- Going back up or next sibling
      | l < st.stateHeaderLevel = go (S l [] st.stateLastPos) (cfg, ps) nodes'
    go st (cfg, ps) (Head pos l name attrs : rest)
      -- We found a config
      | hasArgs "config" attrs = case parseConfig rest of
          (Left err, _) -> Left err
          (Right cfg', rest') -> goWithSingleConfig st (cfg, ps) rest' cfg'
      -- We found a command
      | hasArgs "command" attrs =
          let pt = getKwargs "type" attrs <> st.stateProjectTypes
              isBg = hasArgs "bg" attrs
              posInfo = PosInfo fileName pos l
           in case parseCommand posInfo name pt rest of
                (Left err, _) -> Left err
                (Right p, rest') ->
                  let cmd = p <! bg isBg
                      cmds = addLocation st.stateLastPos posInfo ps
                      st' =
                        st
                          { stateHeaderLevel = l,
                            stateProjectTypes = getKwargs "type" attrs <> parentTypes,
                            stateLastPos = posInfo
                          }
                      parentTypes
                        | l == stateHeaderLevel st = []
                        | otherwise = stateProjectTypes st
                   in go st' (cfg, cmd : cmds) rest'
      -- Pick up project type along the way
      | otherwise =
          let posInfo = PosInfo fileName pos l
              cmds = addLocation st.stateLastPos posInfo ps
           in go st (cfg, cmds) rest
    -- We found a config block
    go st (cfg, ps) (Source lang attrs src : rest)
      | "config" `elem` attrs = case parseConfig (Source lang attrs src : rest) of
          (Left err, _) -> Left err
          (Right cfg', rest') -> goWithSingleConfig st (cfg, ps) rest' cfg'
    -- All other nodes are ignored
    go st ps (_ : rest) = go st ps rest

    goWithSingleConfig st (cfg, ps) rest cfg' = case cfg of
      Just _ -> Left "Found multiple configuration blocks"
      Nothing -> go st (Just cfg', ps) rest

addLocation :: PosInfo -> PosInfo -> [Cmd.Command] -> [Cmd.Command]
addLocation _ _ [] = []
addLocation start next (cmd : rest) = case cmd.cmdLocation of
  Nothing -> cmd {Cmd.cmdLocation = Just loc} : rest
  Just _ -> cmd : rest
  where
    loc =
      Cmd.CommandLocation
        { Cmd.cmdFilePath = start.posName,
          Cmd.cmdStartLine = maybe (-1) M.startLine start.posLocation,
          Cmd.cmdEndLine = maybe 0 M.startLine next.posLocation - 1,
          Cmd.cmdLevel = start.posHeaderLevel
        }

hasArgs :: Text -> Attrs -> Bool
hasArgs key (_, args, _) = key `elem` args

getKwargs :: Text -> Attrs -> [Text]
getKwargs key (_, _, kwargs) = map snd $ filter ((== key) . fst) kwargs

parseConfig :: [Node] -> (Either Text JSON.Config, [Node])
parseConfig (Source lang _ src : rest') = case lang of
  Lang.JSON -> (parseJSON, rest')
  Lang.None -> (parseJSON, rest')
  Lang.YAML -> (parseYAML, rest')
  _ -> (Left $ format ("Invalid config language: " % w) lang, rest')
  where
    parseJSON :: Either Text JSON.Config
    parseJSON = first pack (Aeson.eitherDecodeStrict $ encodeUtf8 src)
    parseYAML :: Either Text JSON.Config
    parseYAML = first (pack . show) (Yaml.decodeEither' $ encodeUtf8 src)
parseConfig rest = (Left "Expecting config source after header", rest)

withPosition :: PosInfo -> Text -> Text
withPosition pos output = T.unwords [positionStr, output]
  where
    positionStr = format (fp % s) (posName pos) lineInfo
    lineInfo = maybe "" (T.pack . (":" ++) . show . M.startLine) location
    location = posLocation pos

parseCommand :: PosInfo -> Text -> [Text] -> [Node] -> (Either Text Cmd.Command, [Node])
parseCommand pos name projectTypes (Paragraph desc : rest) =
  let (cmd, rest') = parseCommand pos name projectTypes rest
   in (Cmd.description (strip desc) <$> cmd, rest')
parseCommand pos name projectTypes (Source lang attrs src : rest) = (cmd, rest)
  where
    cmd = do
      (name', args) <- parseCommandName name
      parsedSourceArgs <- first (T.pack . show) $ P.parse parseCommandArgs "" (T.unwords attrs)
      if not (null args) && not (null parsedSourceArgs)
        then
          Left
            $ withPosition pos
            $ format
              (s % " uses placeholders in both command header and source code block")
              name'
        else
          pure
            Cmd.empty
              { Cmd.cmdName = name',
                Cmd.cmdLang = lang,
                Cmd.cmdPlaceholders = args ++ parsedSourceArgs,
                Cmd.cmdProjectTypes = projectTypes,
                Cmd.cmdSource = src,
                Cmd.cmdLocation = Nothing,
                Cmd.cmdIsHidden = "_" `T.isPrefixOf` name'
              }
parseCommand _ name _ rest = (Left $ format ("Expecting source block for " % s) name, rest)

parseCommandName :: Text -> Either Text (Text, [P.Placeholder])
parseCommandName = first (T.pack . show) . P.parse parser ""
  where
    parser = do
      P.spaces
      (P.eof $> ("", [])) <|> do
        name <- T.pack <$> P.many1 (P.satisfy (not . isSpace))
        args <- parseCommandArgs
        pure (name, args)

parseCommandArgs :: Parser [P.Placeholder]
parseCommandArgs =
  P.choice
    [ (:) <$> parseCommandPlaceholder <*> parseCommandArgs,
      P.anyChar *> parseCommandArgs,
      [] <$ P.eof
    ]

-- | Convenience wrapper for running placeholder parser
parseCommandArg :: String -> Either String P.Placeholder
parseCommandArg = first show . P.parse parseCommandPlaceholder "" . T.pack

parseCommandPlaceholder :: Parser P.Placeholder
parseCommandPlaceholder = do
  let startCmdArg =
        (P.Stdin <$ P.char '<')
          <|> (P.Arg <$ P.char '$')
          <|> (P.EnvVar . T.pack <$> P.many (P.alphaNum <|> P.char '_') <* P.char '=')
  placeholderType <- P.try $ startCmdArg <* P.char '{'
  placeholder <- do
    name <- T.pack <$> P.many1 (P.noneOf " :|}")
    let fixup = T.replace "-" "_"
        placeholderWithName = case placeholderType of
          P.EnvVar "" -> P.EnvVar $ fixup name
          P.EnvVar alias -> P.EnvVar $ fixup alias
          same -> same
    pure $ P.Placeholder placeholderWithName name P.Lines Nothing False False []
  parsePlaceholderModifiers placeholder <* P.char '}'

-- | Parse the "modifiers" which affect how command placeholders are handled.
--
-- This includes:
--
--   * If the placeholder can select multiple values.
--   * Which fields to include from selections.
--   * TODO: Interpret the input as JSON.
--   * TODO: Access JSON attributes through jq-like expressions.
--
-- Formats take on two types, shorthand and pipelines. The following are
-- equivalent:
--
-- Pipeline: `some-command ${placeholder | multiple | fields 1,3}`
-- Shorthand: `some-command ${placeholder:m1,3}`
parsePlaceholderModifiers :: P.Placeholder -> Parser P.Placeholder
parsePlaceholderModifiers placeholder = do
  P.choice
    [ parsePipeModifiers placeholder,
      parseColonModifiers placeholder,
      pure placeholder
    ]
  where
    -- Parse `command-name | fields 1,2 | multiple`
    parsePipeModifiers :: P.Placeholder -> Parser P.Placeholder
    parsePipeModifiers p = do
      _ <- P.many P.space *> P.char '|' *> P.many P.space
      p' <-
        P.choice
          [ P.try $ parsePipeFields p,
            P.try $ parsePipeFilter p,
            P.try $ parsePipeList p,
            P.try $ parsePipeMultiple p
          ]
      _ <- P.many P.space
      P.option p' (parsePipeModifiers p')

    parsePipeFields p =
      -- `cols+h` interprets the first line as a header, `cols` does not
      ( P.string "cols" *> do
          hasHeader <- P.option False (P.string "+h" $> True)
          P.many P.space *> parseFields (P.Columns hasHeader) p
      )
        <|> (P.string "fields" *> P.many P.space *> parseFields P.Fields p)
        <|> (P.string "json" $> p {P.format = P.JSON})

    -- Parse `filter "some-filter"`
    parsePipeFilter p = do
      _ <- (P.string "filter" :: Parser String) *> P.many P.space
      f <- P.between (P.char '"') (P.char '"') (P.many P.alphaNum)
      pure p {P.filter = Just $ pack f}

    parsePipeList p = (P.string "list" :: Parser String) $> p {P.list = True}

    parsePipeMultiple p = (P.string "multi" :: Parser String) $> p {P.multiple = True}

    -- Parse `command-name:1,2`
    parseColonModifiers :: P.Placeholder -> Parser P.Placeholder
    parseColonModifiers p = do
      _ <- P.char ':'
      -- Accept fields and multiple in any order
      (parseFields P.Fields p >>= perhaps parseMultiple) <|> (parseMultiple p >>= perhaps (parseFields P.Fields))

    parseFields :: ([Int] -> P.PlaceholderFormat) -> P.Placeholder -> Parser P.Placeholder
    parseFields fieldType p' = do
      fields <- mapMaybe readMaybe <$> (P.many1 P.digit `P.sepBy1` P.char ',')
      when (p'.format /= P.Lines) $ fail "Placeholder format already set"
      pure $ p' {P.format = fieldType fields}

    parseMultiple :: P.Placeholder -> Parser P.Placeholder
    parseMultiple p' = do
      multiple <- P.option False (True <$ P.char 'm')
      pure $ p' {P.multiple = multiple}

    -- Try a parser or default to `value`
    perhaps parser value = P.option value (parser value)
