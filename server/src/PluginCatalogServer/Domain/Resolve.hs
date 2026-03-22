{-# LANGUAGE OverloadedStrings #-}

module PluginCatalogServer.Domain.Resolve
  ( ResolvedPlugin(..)
  , resolvePluginByCapability
  , promotePluginChannel
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Control.Monad.IO.Class (MonadIO)
import Database.Persist
import Database.Persist.Sql (SqlPersistT)
import PluginCatalogServer.Domain.Manifest
import PluginCatalogServer.Model
import PluginCatalogServer.Settings (AppSettings, makeAbsoluteUrl)

data ResolvedPlugin = ResolvedPlugin
  { rpCapability :: Text
  , rpSource :: Text
  , rpManifest :: Value
  }

resolvePluginByCapability :: MonadIO m => AppSettings -> Text -> Text -> Maybe Text -> SqlPersistT m (Maybe ResolvedPlugin)
resolvePluginByCapability settings capability platform channel = do
  capabilityRows <- selectList [PluginCapabilityCapability ==. capability] []
  findFirst capabilityRows
  where
    findFirst [] = pure Nothing
    findFirst (Entity _ capRow : rest) = do
      version <- get (pluginCapabilityPluginVersionId capRow)
      case version of
        Nothing -> findFirst rest
        Just versionRow
          | pluginVersionPlatform versionRow /= platform -> findFirst rest
          | pluginVersionStatus versionRow /= "active" -> findFirst rest
          | otherwise -> do
              channelAllowed <- matchesRequestedChannel (pluginVersionPluginId versionRow) (pluginVersionVersion versionRow)
              if not channelAllowed
                then findFirst rest
                else do
                  plugin <- getJust (pluginVersionPluginId versionRow)
                  caps <- selectList [PluginCapabilityPluginVersionId ==. pluginCapabilityPluginVersionId capRow] []
                  let manifest =
                        renderManifestValue
                          PluginManifestV2
                            { pmName = pluginName plugin
                            , pmPublisher = pluginPublisher plugin
                            , pmVersion = pluginVersionVersion versionRow
                            , pmRuntime = pluginVersionRuntime versionRow
                            , pmPlatform = pluginVersionPlatform versionRow
                            , pmEntrypoint = pluginVersionEntrypoint versionRow
                            , pmArtifact =
                                ArtifactRef
                                  { arUrl = makeAbsoluteUrl settings ("/artifacts/" <> pluginName plugin <> "/" <> pluginVersionVersion versionRow <> "/bundle")
                                  , arSha256 = pluginVersionSha256 versionRow
                                  , arSizeBytes = pluginVersionSizeBytes versionRow
                                  }
                            , pmCapabilities = map (pluginCapabilityCapability . entityVal) caps
                            , pmSandbox = SandboxConfig {scTimeoutSeconds = Just 30}
                            }
                  pure $
                    Just
                      ResolvedPlugin
                        { rpCapability = capability
                        , rpSource = maybe "catalog" (\value -> "catalog:" <> value) channel
                        , rpManifest = manifest
                        }

    matchesRequestedChannel pluginId version =
      case channel of
        Just channelName -> do
          row <- getBy (UniquePluginChannel pluginId channelName)
          pure $
            case row of
              Just (Entity _ pluginChannel) -> pluginChannelVersion pluginChannel == version
              Nothing -> False
        Nothing -> do
          stable <- getBy (UniquePluginChannel pluginId "stable")
          latest <- getBy (UniquePluginChannel pluginId "latest")
          pure $
            case stable of
              Just (Entity _ pluginChannel) -> pluginChannelVersion pluginChannel == version
              Nothing ->
                case latest of
                  Just (Entity _ pluginChannel) -> pluginChannelVersion pluginChannel == version
                  Nothing -> True

promotePluginChannel :: MonadIO m => PluginId -> Text -> Text -> SqlPersistT m ()
promotePluginChannel pluginId version channel = do
  existing <- getBy (UniquePluginChannel pluginId channel)
  case existing of
    Nothing ->
      insert_
        PluginChannel
          { pluginChannelPluginId = pluginId
          , pluginChannelChannel = channel
          , pluginChannelVersion = version
          }
    Just (Entity channelId _) ->
      update channelId [PluginChannelVersion =. version]
