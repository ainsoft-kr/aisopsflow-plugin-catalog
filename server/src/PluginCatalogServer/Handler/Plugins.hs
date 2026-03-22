{-# LANGUAGE OverloadedStrings #-}

module PluginCatalogServer.Handler.Plugins
  ( getPluginsR
  , getPluginR
  , getPluginManifestR
  , getPluginCatalogManifestR
  , postPromotePluginR
  , getResolvePluginR
  ) where

import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import Data.Aeson ((.:))
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Yaml as Yaml
import Database.Persist
import PluginCatalogServer.Domain.Resolve
import PluginCatalogServer.Foundation
import PluginCatalogServer.Model
import Yesod

newtype PromoteRequest = PromoteRequest
  { prChannel :: Text
  }

instance FromJSON PromoteRequest where
  parseJSON = Aeson.withObject "PromoteRequest" $ \o ->
    PromoteRequest <$> o .: "channel"

getPluginsR :: Handler Value
getPluginsR = do
  plugins <- runDB $ selectList [] [Asc PluginName]
  returnJson
    [ object
        [ "name" .= pluginName row
        , "publisher" .= pluginPublisher row
        , "latest_version" .= pluginLatestVersion row
        ]
    | Entity _ row <- plugins
    ]

getPluginR :: Text -> Handler Value
getPluginR pluginNameText = do
  Entity pluginId pluginRow <- runDB $ getBy404 (UniquePluginName pluginNameText)
  versions <- runDB $ selectList [PluginVersionPluginId ==. pluginId] [Desc PluginVersionCreatedAt]
  channels <- runDB $ selectList [PluginChannelPluginId ==. pluginId] [Asc PluginChannelChannel]
  returnJson $
    object
      [ "name" .= pluginName pluginRow
      , "publisher" .= pluginPublisher pluginRow
      , "latest_version" .= pluginLatestVersion pluginRow
      , "channels"
          .= [ object
                [ "channel" .= pluginChannelChannel channelRow
                , "version" .= pluginChannelVersion channelRow
                ]
             | Entity _ channelRow <- channels
             ]
      , "versions"
          .= [ object
                [ "version" .= pluginVersionVersion row
                , "platform" .= pluginVersionPlatform row
                , "runtime" .= pluginVersionRuntime row
                , "status" .= pluginVersionStatus row
                , "catalog_manifest_path"
                    .= ("/api/plugins/" <> pluginName pluginRow <> "/" <> pluginVersionVersion row <> "/catalog-manifest" :: Text)
                , "runtime_manifest_path"
                    .= ("/api/plugins/" <> pluginName pluginRow <> "/" <> pluginVersionVersion row <> "/manifest" :: Text)
                ]
             | Entity _ row <- versions
             ]
      ]

getPluginManifestR :: Text -> Text -> Handler Value
getPluginManifestR pluginName version = do
  pluginEntity <- runDB $ getBy404 (UniquePluginName pluginName)
  let pluginId = entityKey pluginEntity
  mVersion <-
    runDB $
      selectFirst
        [ PluginVersionPluginId ==. pluginId
        , PluginVersionVersion ==. version
        ]
        []
  case mVersion of
    Nothing -> notFound
    Just (Entity _ row) ->
      case Aeson.decodeStrict' (encodeUtf8 (pluginVersionManifestJson row)) of
        Nothing -> invalidArgs ["stored manifest_json is invalid"]
        Just manifest -> returnJson (manifest :: Value)

getPluginCatalogManifestR :: Text -> Text -> Handler Value
getPluginCatalogManifestR pluginName version = do
  pluginEntity <- runDB $ getBy404 (UniquePluginName pluginName)
  let pluginId = entityKey pluginEntity
  mVersion <-
    runDB $
      selectFirst
        [ PluginVersionPluginId ==. pluginId
        , PluginVersionVersion ==. version
        ]
        []
  case mVersion of
    Nothing -> notFound
    Just (Entity _ row) ->
      case Aeson.decodeStrict' (encodeUtf8 (pluginVersionCatalogManifestJson row)) of
        Nothing -> invalidArgs ["stored catalog_manifest_json is invalid"]
        Just manifest -> sendResponse ("application/yaml" :: ContentType, toContent (Yaml.encode (manifest :: Value)))

getResolvePluginR :: Text -> Handler Value
getResolvePluginR capability = do
  app <- getYesod
  platform <- runInputGet $ ireq textField "platform"
  channel <- runInputGet $ iopt textField "channel"
  resolved <- runDB $ resolvePluginByCapability (appSettings app) capability platform channel
  case resolved of
    Nothing -> notFound
    Just result ->
      returnJson $
        object
          [ "capability" .= rpCapability result
          , "source" .= rpSource result
          , "plugin" .= rpManifest result
          ]

postPromotePluginR :: Text -> Text -> Handler Value
postPromotePluginR pluginName version = do
  PromoteRequest channel <- requireCheckJsonBody
  Entity pluginId _ <- runDB $ getBy404 (UniquePluginName pluginName)
  existingVersion <-
    runDB $
      selectFirst
        [ PluginVersionPluginId ==. pluginId
        , PluginVersionVersion ==. version
        ]
        []
  case existingVersion of
    Nothing -> notFound
    Just _ -> do
      runDB $ promotePluginChannel pluginId version channel
      returnJson $
        object
          [ "name" .= pluginName
          , "version" .= version
          , "channel" .= channel
          , "status" .= ("promoted" :: Text)
          ]
