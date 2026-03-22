{-# LANGUAGE OverloadedStrings #-}

module PluginCatalogServer.Handler.Publish
  ( postPublishPluginR
  , PublishResult(..)
  , publishPluginFromBody
  , publishPluginFromBodySafe
  ) where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Control.Exception (SomeException, try)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (getCurrentTime)
import Database.Persist
import Network.HTTP.Types.Status (status201)
import PluginCatalogServer.Domain.Manifest
import PluginCatalogServer.Domain.Resolve (promotePluginChannel)
import PluginCatalogServer.Foundation
import PluginCatalogServer.Model
import PluginCatalogServer.Settings (AppSettings(..), makeAbsoluteUrl)
import System.Directory (createDirectoryIfMissing, getFileSize, renameFile)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.IO (hClose, openBinaryTempFile)
import System.Process (readProcessWithExitCode)
import Yesod

data PublishRequest = PublishRequest
  { prName :: Text
  , prVersion :: Text
  , prPublisher :: Text
  , prRuntime :: Text
  , prPlatform :: Text
  , prEntrypoint :: Text
  , prCapabilities :: [Text]
  }

data PublishResult = PublishResult
  { pbrName :: Text
  , pbrVersion :: Text
  , pbrSha256 :: Text
  }

postPublishPluginR :: Handler Value
postPublishPluginR = do
  result <- publishPluginFromBody True
  sendStatusJSON
    status201
    ( object
        [ "name" .= pbrName result
        , "version" .= pbrVersion result
        , "sha256" .= pbrSha256 result
        , "status" .= ("published" :: Text)
        ]
    )

publishPluginFromBody :: Bool -> Handler PublishResult
publishPluginFromBody requireToken = do
  outcome <- publishPluginFromBodySafe requireToken
  case outcome of
    Right result -> pure result
    Left err
      | err == "missing publish token" || err == "invalid publish token" -> permissionDenied err
      | otherwise -> invalidArgs [err]

publishPluginFromBodySafe :: Bool -> Handler (Either Text PublishResult)
publishPluginFromBodySafe requireToken = do
  app <- getYesod
  if requireToken
    then do
      authHeader <- lookupHeader "X-Plugin-Catalog-Token"
      case authHeader of
        Nothing -> pure (Left "missing publish token")
        Just token | token /= encodeUtf8 (appUploadToken (appSettings app)) -> pure (Left "invalid publish token")
        _ -> continuePublish app
    else continuePublish app
  where
    continuePublish app = do
      (formFields, formFiles) <- runRequestBody
      case parsePublishRequestSafe formFields of
        Left err -> pure (Left err)
        Right req ->
          case lookupBundleFileSafe formFiles of
            Left err -> pure (Left err)
            Right bundleFile -> do
              now <- liftIO getCurrentTime
              ioResult <-
                liftIO $
                  (try
                    (
                    do
                      tmpBundlePath <- persistUploadedFile (appArtifactRoot (appSettings app)) bundleFile
                      sizeBytes <- fromIntegral <$> getFileSize tmpBundlePath
                      sha256 <- sha256FileHex tmpBundlePath
                      validateBundleArchive tmpBundlePath (prEntrypoint req)
                      let artifactRelPath = T.unpack (prName req) </> T.unpack (prVersion req) </> "bundle.tar.gz"
                          artifactAbsPath = appArtifactRoot (appSettings app) </> artifactRelPath
                      createDirectoryIfMissing True (takeDirectory artifactAbsPath)
                      renameFile tmpBundlePath artifactAbsPath
                      pure (tmpBundlePath, sizeBytes, sha256, artifactRelPath)
                    ) :: IO (Either SomeException (FilePath, Int, Text, FilePath)))
              case ioResult of
                Left err -> pure (Left (T.pack (show err)))
                Right (_, sizeBytes, sha256, artifactRelPath) -> do
                  let bundleUrl = makeAbsoluteUrl (appSettings app) ("/artifacts/" <> prName req <> "/" <> prVersion req <> "/bundle")
                  pluginId <- runDB $ upsertPlugin req
                  let manifestValue =
                        renderManifestValue
                          PluginManifestV2
                            { pmName = prName req
                            , pmPublisher = prPublisher req
                            , pmVersion = prVersion req
                            , pmRuntime = prRuntime req
                            , pmPlatform = prPlatform req
                            , pmEntrypoint = prEntrypoint req
                            , pmArtifact =
                                ArtifactRef
                                  { arUrl = bundleUrl
                                  , arSha256 = sha256
                                  , arSizeBytes = sizeBytes
                                  }
                            , pmCapabilities = prCapabilities req
                            , pmSandbox = SandboxConfig {scTimeoutSeconds = Just 30}
                            }
                      catalogManifestValue =
                        renderCatalogManifestValue
                          CatalogManifestV1
                            { cmName = prName req
                            , cmPublisher = prPublisher req
                            , cmVersion = prVersion req
                            , cmPluginRef = bundleUrl
                            , cmManifestPath = "runner-plugin.yaml"
                            , cmCapabilities = prCapabilities req
                            }
                      manifestJson = decodeUtf8 (BL.toStrict (Aeson.encode manifestValue))
                      catalogManifestJson = decodeUtf8 (BL.toStrict (Aeson.encode catalogManifestValue))

                  versionId <-
                    runDB $
                      insertUnique
                        PluginVersion
                          { pluginVersionPluginId = pluginId
                          , pluginVersionVersion = prVersion req
                          , pluginVersionRuntime = prRuntime req
                          , pluginVersionPlatform = prPlatform req
                          , pluginVersionEntrypoint = prEntrypoint req
                          , pluginVersionArtifactPath = T.pack artifactRelPath
                          , pluginVersionSha256 = sha256
                          , pluginVersionSizeBytes = sizeBytes
                          , pluginVersionManifestJson = manifestJson
                          , pluginVersionCatalogManifestJson = catalogManifestJson
                          , pluginVersionStatus = "active"
                          , pluginVersionCreatedAt = now
                          }

                  insertedIdEither <-
                    case versionId of
                      Just newId -> pure (Right newId)
                      Nothing -> do
                        existing <- runDB $ getBy (UniquePluginName (prName req))
                        case existing of
                          Nothing -> pure (Left "publish failed to create plugin version")
                          Just (Entity pid _) -> do
                            existingVersion <-
                              runDB $
                                selectFirst
                                  [ PluginVersionPluginId ==. pid
                                  , PluginVersionVersion ==. prVersion req
                                  , PluginVersionPlatform ==. prPlatform req
                                  ]
                                  []
                            pure $
                              case existingVersion of
                                Nothing -> Left "publish failed to create plugin version"
                                Just (Entity existingId _) -> Right existingId

                  case insertedIdEither of
                    Left err -> pure (Left err)
                    Right insertedId -> do
                      runDB $
                        update
                          insertedId
                          [ PluginVersionManifestJson =. manifestJson
                          , PluginVersionCatalogManifestJson =. catalogManifestJson
                          , PluginVersionArtifactPath =. T.pack artifactRelPath
                          , PluginVersionSha256 =. sha256
                          , PluginVersionSizeBytes =. sizeBytes
                          , PluginVersionEntrypoint =. prEntrypoint req
                          , PluginVersionRuntime =. prRuntime req
                          , PluginVersionPlatform =. prPlatform req
                          , PluginVersionStatus =. "active"
                          ]
                      runDB $ deleteWhere [PluginCapabilityPluginVersionId ==. insertedId]
                      runDB $
                        insertMany_
                          [ PluginCapability insertedId capability
                          | capability <- prCapabilities req
                          ]
                      runDB $ update pluginId [PluginLatestVersion =. Just (prVersion req)]
                      runDB $ promotePluginChannel pluginId (prVersion req) "latest"
                      pure $
                        Right
                          PublishResult
                            { pbrName = prName req
                            , pbrVersion = prVersion req
                            , pbrSha256 = sha256
                            }
    upsertPlugin req = do
      existing <- getBy (UniquePluginName (prName req))
      case existing of
        Just (Entity pluginId _) -> pure pluginId
        Nothing ->
          insert
            Plugin
              { pluginName = prName req
              , pluginPublisher = prPublisher req
              , pluginLatestVersion = Just (prVersion req)
              }

parsePublishRequestSafe :: [(Text, Text)] -> Either Text PublishRequest
parsePublishRequestSafe formFields =
  PublishRequest
    <$> requireFormTextSafe formFields "name"
    <*> requireFormTextSafe formFields "version"
    <*> requireFormTextSafe formFields "publisher"
    <*> requireFormTextSafe formFields "runtime"
    <*> requireFormTextSafe formFields "platform"
    <*> requireFormTextSafe formFields "entrypoint"
    <*> (parseCapabilities <$> requireFormTextSafe formFields "capabilities")

requireFormTextSafe :: [(Text, Text)] -> Text -> Either Text Text
requireFormTextSafe formFields fieldName =
  case lookup fieldName formFields of
    Just value | not (T.null (T.strip value)) -> Right (T.strip value)
    _ -> Left (fieldName <> " is required")

parseCapabilities :: Text -> [Text]
parseCapabilities =
  filter (not . T.null)
    . map T.strip
    . T.splitOn ","

lookupBundleFileSafe :: [(Text, FileInfo)] -> Either Text FileInfo
lookupBundleFileSafe formFiles =
  case lookup "bundle" formFiles of
    Just fileInfo -> Right fileInfo
    Nothing -> Left "bundle file is required"

persistUploadedFile :: FilePath -> FileInfo -> IO FilePath
persistUploadedFile artifactRoot fileInfo = do
  let tmpDir = artifactRoot </> "_tmp"
  createDirectoryIfMissing True tmpDir
  (tmpPath, handle) <- openBinaryTempFile tmpDir "upload-bundle.tar.gz"
  hClose handle
  fileMove fileInfo tmpPath
  pure tmpPath

sha256FileHex :: FilePath -> IO Text
sha256FileHex path = do
  body <- BL.readFile path
  pure . T.pack . show $ (hashlazy body :: Digest SHA256)

validateBundleArchive :: FilePath -> Text -> IO ()
validateBundleArchive archivePath entrypoint = do
  (exitCode, stdoutText, stderrText) <- readProcessWithExitCode "tar" ["-tzf", archivePath] ""
  case exitCode of
    ExitSuccess -> do
      let entries = normalizeArchiveEntries (lines stdoutText)
          wantedEntrypoint = normalizeArchiveEntry (T.unpack entrypoint)
      if not ("runner-plugin.yaml" `elem` entries)
        then fail "bundle missing runner-plugin.yaml"
        else
          if wantedEntrypoint `elem` entries
            then pure ()
            else fail ("bundle missing declared entrypoint: " <> T.unpack entrypoint)
    ExitFailure _ ->
      fail ("invalid tar.gz bundle: " <> stderrText)

normalizeArchiveEntries :: [String] -> [String]
normalizeArchiveEntries = map normalizeArchiveEntry

normalizeArchiveEntry :: String -> String
normalizeArchiveEntry =
  dropWhile (== '/')
    . dropDotPrefix
  where
    dropDotPrefix ('.' : '/' : rest) = dropDotPrefix rest
    dropDotPrefix value = value
