{-# LANGUAGE OverloadedStrings #-}

module PluginCatalogServer.Handler.Artifacts
  ( getPluginBundleR
  , getPluginDigestR
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import qualified Data.Text as T
import Database.Persist
import PluginCatalogServer.Foundation
import PluginCatalogServer.Model
import PluginCatalogServer.Settings
import System.FilePath ((</>))
import Yesod

getPluginBundleR :: Text -> Text -> Handler TypedContent
getPluginBundleR pluginName version = do
  app <- getYesod
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
    Just (Entity _ row) -> do
      let absPath = appArtifactRoot (appSettings app) </> T.unpack (pluginVersionArtifactPath row)
      sendFile "application/gzip" absPath

getPluginDigestR :: Text -> Text -> Handler Value
getPluginDigestR pluginName version = do
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
      returnJson $
        object
          [ "name" .= pluginName
          , "version" .= version
          , "sha256" .= pluginVersionSha256 row
          ]
