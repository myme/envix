module Nixon.Project.Defaults
  ( default_projects
  ) where

import           Control.Monad.Trans.Maybe
import           Data.Aeson
import           Data.Aeson.Types
import qualified Data.HashMap.Strict as Map
import qualified Data.Text as T
import           Nixon.Nix
import           Nixon.Project
import           Nixon.Project.Types
import qualified Nixon.Select as Select
import           Nixon.Select (Candidate)
import           Nixon.Utils
import           Prelude hiding (FilePath)
import           Turtle hiding (text)

candidate_lines :: Line -> Candidate
candidate_lines = Select.Identity . lineToText

-- | Find NPM scripts from a project package.json file
npm_scripts :: Command
npm_scripts = Command [ShellPart "script" scripts] mempty
  where
    parse_script = withObject "package.json" (.: "scripts")
    scripts project = Select.select $ do
      content <- liftIO $ runMaybeT $ do
        package <- MaybeT $ find_dominating_file (project_path project) "package.json"
        MaybeT $ decodeFileStrict (T.unpack $ format fp package)
      let elems = do
            map' <- parseMaybe parse_script =<< content
            pure (Map.toList (map' :: Map.HashMap Text Text))
      select $ maybe [] (map $ \(k, v) -> Select.WithTitle (format (s%" - "%s) k v) k) elems

-- | Placeholder for a git revision
revision :: Command
revision = Command [ShellPart "revision" revisions] mempty
  where revisions project = fmap (fmap takeToSpace) $ Select.select $ do
          pushd (project_path project)
          candidate_lines <$> inshell "git log --oneline --color" mempty

rg_files :: Command
rg_files = Command [ShellPart "filename" files] mempty
  where files project = Select.select $ do
          pushd (project_path project)
          candidate_lines <$> inshell "rg --files" mempty

git_files :: Command
git_files = Command [ShellPart "filename" files] mempty
  where files project = Select.select $ do
          pushd (project_path project)
          candidate_lines <$> inshell "git ls-files" mempty

-- TODO: Add support for local overrides with an .nixon project file
default_projects :: [ProjectType]
default_projects =
  [proj ["cabal.project"] "Cabal new-style project"
   ["cabal new-build" ! desc "Cabal build"
   ,"cabal new-repl" ! desc "Cabal repl"
   ,"cabal new-run" ! desc "Cabal run"
   ,"cabal new-test" ! desc "Cabal test"
   ]
  ,proj ["package.json"] "NPM project"
   ["npm run" <> npm_scripts ! desc "Run npm scripts"
   ,"npm install" ! desc "NPM install"
   ,"npm start" ! desc "NPM run"
   ,"npm test" ! desc "NPM test"
   ]
  ,proj ["yarn.lock"] "Yarn project"
   ["yarn run" <> npm_scripts ! desc "Run yarn scripts"
   ,"yarn install" ! desc "Yarn install"
   ,"yarn start" ! desc "Yarn run"
   ,"yarn test" ! desc "Yarn test"
   ]
  ,proj [ProjectOr $ map ProjectFile nix_files] "Nix project"
   ["nix-build" ! desc "Nix build"
   ,"nix-shell" ! desc "Nix shell"
   ]
  ,proj [".envrc"] "Direnv project"
   ["direnv allow" ! desc "Direnv allow"
   ,"direnv deny" ! desc "Direnv deny"
   ,"direnv reload" ! desc "Direnv reload"
   ]
  ,proj [".git"] "Git repository"
   ["git blame" <> revision <> git_files ! desc "Git blame"
   ,"git fetch" ! desc "Git fetch"
   ,"git log" ! desc "Git log"
   ,"git rebase" ! desc "Git rebase"
   ,"git show" <> revision ! desc "Git show"
   ,"git status" ! desc "Git status"
   -- Uses "git ls-files"
   ,"vim" <> rg_files ! desc "Vim"
   ,"bat" <> rg_files ! desc "Preview file"
   -- git log --color --pretty=format:"%C(green)%h %C(blue)%cr %Creset%s%C(yellow)%d %Creset%C(cyan)<%ae>%Creset" | fzf +s --ansi --preview='git show --color {1}'
   ]
  ,proj [".hg"] "Mercurial project" []
  ,proj [".project"] "Ad-hoc project" []
  ,proj [] "Generic project"
   ["x-terminal-emulator" ! desc "Terminal" <> gui
   ,"emacs" ! desc "Emacs" <> gui
   ,"dolphin" <> path ! desc "Files" <> gui
   ,"rofi -show run" ! desc "Run" <> gui
   ]
  ]
