{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

module PluginCatalogServer.Foundation
  ( App(..)
  , Handler
  , Route(..)
  , resourcesApp
  , runDB
  ) where

import Data.Text (Text)
import Database.Persist.Sqlite (ConnectionPool, SqlBackend, runSqlPool)
import Network.HTTP.Client (Manager)
import PluginCatalogServer.Settings (AppSettings(..))
import Yesod

data App = App
  { appSettings :: AppSettings
  , appConnPool :: ConnectionPool
  , appHttpManager :: Manager
  }

mkYesodData "App" $(parseRoutesFile "config/routes")

instance Yesod App

instance YesodPersist App where
  type YesodPersistBackend App = SqlBackend
  runDB action = do
    master <- getYesod
    runSqlPool action (appConnPool master)

instance RenderMessage App FormMessage where
  renderMessage _ _ = defaultFormMessage
