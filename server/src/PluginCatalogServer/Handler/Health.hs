{-# LANGUAGE OverloadedStrings #-}

module PluginCatalogServer.Handler.Health
  ( getHealthR
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import PluginCatalogServer.Foundation
import Yesod (returnJson)

getHealthR :: Handler Value
getHealthR =
  returnJson $
    object
      [ "ok" .= True
      , "service" .= ("plugin-catalog-server" :: Text)
      ]
