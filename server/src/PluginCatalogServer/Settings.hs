{-# LANGUAGE OverloadedStrings #-}

module PluginCatalogServer.Settings
  ( AppSettings(..)
  , loadAppSettings
  , makeAbsoluteUrl
  , shouldUseSecureCookies
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data AppSettings = AppSettings
  { appPort :: Int
  , appSqlitePath :: Text
  , appArtifactRoot :: FilePath
  , appMaxUploadBytes :: Integer
  , appUploadToken :: Text
  , appAdminToken :: Maybe Text
  , appBootstrapAdminUsername :: Maybe Text
  , appBootstrapAdminPassword :: Maybe Text
  , appBootstrapAdminDisplayName :: Maybe Text
  , appSeedOwnerPassword :: Maybe Text
  , appSeedAdminPassword :: Maybe Text
  , appSeedPublisherPassword :: Maybe Text
  , appSeedViewerPassword :: Maybe Text
  , appBaseUrl :: Text
  }
  deriving (Eq, Show)

loadAppSettings :: IO AppSettings
loadAppSettings = do
  port <- readEnvInt "PLUGIN_CATALOG_PORT" 3100
  sqlitePath <- readEnvText "PLUGIN_CATALOG_DB" "plugin-catalog.db"
  artifactRoot <- readEnvString "PLUGIN_CATALOG_ARTIFACT_ROOT" "./artifacts"
  maxUploadBytes <- readEnvInteger "PLUGIN_CATALOG_MAX_UPLOAD_BYTES" (100 * 1024 * 1024)
  uploadToken <- readEnvText "PLUGIN_CATALOG_UPLOAD_TOKEN" "dev-token"
  adminToken <- readEnvMaybeText "PLUGIN_CATALOG_ADMIN_TOKEN"
  bootstrapAdminUsername <- readEnvMaybeText "PLUGIN_CATALOG_BOOTSTRAP_ADMIN_USERNAME"
  bootstrapAdminPassword <- readEnvMaybeText "PLUGIN_CATALOG_BOOTSTRAP_ADMIN_PASSWORD"
  bootstrapAdminDisplayName <- readEnvMaybeText "PLUGIN_CATALOG_BOOTSTRAP_ADMIN_DISPLAY_NAME"
  seedOwnerPassword <- readEnvMaybeText "PLUGIN_CATALOG_SEED_OWNER_PASSWORD"
  seedAdminPassword <- readEnvMaybeText "PLUGIN_CATALOG_SEED_ADMIN_PASSWORD"
  seedPublisherPassword <- readEnvMaybeText "PLUGIN_CATALOG_SEED_PUBLISHER_PASSWORD"
  seedViewerPassword <- readEnvMaybeText "PLUGIN_CATALOG_SEED_VIEWER_PASSWORD"
  baseUrl <- readEnvText "PLUGIN_CATALOG_BASE_URL" "http://127.0.0.1:3100"
  pure
    AppSettings
      { appPort = port
      , appSqlitePath = sqlitePath
      , appArtifactRoot = artifactRoot
      , appMaxUploadBytes = maxUploadBytes
      , appUploadToken = uploadToken
      , appAdminToken = adminToken
      , appBootstrapAdminUsername = bootstrapAdminUsername
      , appBootstrapAdminPassword = bootstrapAdminPassword
      , appBootstrapAdminDisplayName = bootstrapAdminDisplayName
      , appSeedOwnerPassword = seedOwnerPassword
      , appSeedAdminPassword = seedAdminPassword
      , appSeedPublisherPassword = seedPublisherPassword
      , appSeedViewerPassword = seedViewerPassword
      , appBaseUrl = baseUrl
      }

readEnvText :: String -> Text -> IO Text
readEnvText key fallback = maybe fallback T.pack <$> lookupEnv key

readEnvMaybeText :: String -> IO (Maybe Text)
readEnvMaybeText key = do
  raw <- lookupEnv key
  pure $
    case fmap T.strip (T.pack <$> raw) of
      Just value | not (T.null value) -> Just value
      _ -> Nothing

readEnvString :: String -> String -> IO String
readEnvString key fallback = maybe fallback id <$> lookupEnv key

readEnvInt :: String -> Int -> IO Int
readEnvInt key fallback = do
  raw <- lookupEnv key
  pure $ maybe fallback id (raw >>= readMaybe)

readEnvInteger :: String -> Integer -> IO Integer
readEnvInteger key fallback = do
  raw <- lookupEnv key
  pure $ maybe fallback id (raw >>= readMaybe)

makeAbsoluteUrl :: AppSettings -> Text -> Text
makeAbsoluteUrl settings path =
  stripTrailingSlash (appBaseUrl settings) <> ensureLeadingSlash path
  where
    stripTrailingSlash = T.dropWhileEnd (== '/')
    ensureLeadingSlash value
      | T.isPrefixOf "/" value = value
      | otherwise = "/" <> value

shouldUseSecureCookies :: AppSettings -> Bool
shouldUseSecureCookies settings =
  "https://" `T.isPrefixOf` T.toLower (appBaseUrl settings)
