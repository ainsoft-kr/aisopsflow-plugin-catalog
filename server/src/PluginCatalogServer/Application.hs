{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

module PluginCatalogServer.Application
  ( runApp
  ) where

import Control.Monad.Logger (runStdoutLoggingT)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Database.Persist (Entity(..), getBy, insert, (=.))
import Database.Persist.Sql (update)
import Database.Persist.Sqlite (ConnectionPool, SqlPersistT, createSqlitePool, runMigration, runSqlPool)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.Wai.Handler.Warp (run)
import PluginCatalogServer.Auth (hashPassword)
import PluginCatalogServer.Foundation
import PluginCatalogServer.Handler.Admin
import PluginCatalogServer.Handler.Artifacts
import PluginCatalogServer.Handler.Health
import PluginCatalogServer.Handler.Plugins
import PluginCatalogServer.Handler.Publish
import PluginCatalogServer.Model
import PluginCatalogServer.Settings
import System.Directory (createDirectoryIfMissing)
import Yesod (mkYesodDispatch, toWaiAppPlain)

mkYesodDispatch "App" resourcesApp

runApp :: IO ()
runApp = do
  settings <- loadAppSettings
  createDirectoryIfMissing True (appArtifactRoot settings)
  manager <- newTlsManager
  pool <- runStdoutLoggingT (createSqlitePool (appSqlitePath settings) 1)
  runSqlPool (runMigration migrateAll) pool
  ensureBootstrapAdmin settings pool
  ensureSeedAdminUsers settings pool
  let app =
        App
          { appSettings = settings
          , appConnPool = pool
          , appHttpManager = manager
          }
  run (appPort settings) =<< toWaiAppPlain app

ensureBootstrapAdmin :: AppSettings -> ConnectionPool -> IO ()
ensureBootstrapAdmin settings pool =
  case (appBootstrapAdminUsername settings, appBootstrapAdminPassword settings) of
    (Just username, Just password) ->
      runSqlPool (ensureBootstrapAdminSql username password displayName) pool
    _ -> pure ()
  where
    displayName = maybe "Administrator" id (appBootstrapAdminDisplayName settings)

ensureBootstrapAdminSql :: Text -> Text -> Text -> SqlPersistT IO ()
ensureBootstrapAdminSql username password displayName = do
  existing <- getBy (UniqueAdminUsername username)
  now <- liftIO getCurrentTime
  case existing of
    Just (Entity userId userRow) ->
      case adminUserRole userRow of
        Just _ -> pure ()
        Nothing ->
          update
            userId
            [ AdminUserRole =. Just "owner"
            , AdminUserUpdatedAt =. now
            ]
    Nothing -> do
      passwordHash <- liftIO (hashPassword password)
      _ <-
        insert
          AdminUser
            { adminUserUsername = username
            , adminUserDisplayName = displayName
            , adminUserRole = Just "owner"
            , adminUserPasswordHash = passwordHash
            , adminUserIsActive = True
            , adminUserCreatedAt = now
            , adminUserUpdatedAt = now
            , adminUserLastLoginAt = Nothing
            }
      pure ()

ensureSeedAdminUsers :: AppSettings -> ConnectionPool -> IO ()
ensureSeedAdminUsers settings pool =
  mapM_
    (\(username, displayName, role, password) ->
      case password of
        Just rawPassword ->
          runSqlPool (ensureSeedAdminUserSql username displayName role rawPassword) pool
        Nothing -> pure ()
    )
    seedSpecs
  where
    seedSpecs =
      [ ("owner", "Catalog Owner", "owner", appSeedOwnerPassword settings)
      , ("admin", "Catalog Admin", "admin", appSeedAdminPassword settings)
      , ("publisher", "Catalog Publisher", "publisher", appSeedPublisherPassword settings)
      , ("viewer", "Catalog Viewer", "viewer", appSeedViewerPassword settings)
      ]

ensureSeedAdminUserSql :: Text -> Text -> Text -> Text -> SqlPersistT IO ()
ensureSeedAdminUserSql username displayName role password = do
  existing <- getBy (UniqueAdminUsername username)
  now <- liftIO getCurrentTime
  case existing of
    Nothing -> do
      passwordHash <- liftIO (hashPassword password)
      _ <-
        insert
          AdminUser
            { adminUserUsername = username
            , adminUserDisplayName = displayName
            , adminUserRole = Just role
            , adminUserPasswordHash = passwordHash
            , adminUserIsActive = True
            , adminUserCreatedAt = now
            , adminUserUpdatedAt = now
            , adminUserLastLoginAt = Nothing
            }
      pure ()
    Just (Entity userId userRow) ->
      case adminUserRole userRow of
        Just _ -> pure ()
        Nothing ->
          update
            userId
            [ AdminUserRole =. Just role
            , AdminUserUpdatedAt =. now
            ]
