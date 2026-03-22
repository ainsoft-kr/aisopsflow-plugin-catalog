{-# LANGUAGE OverloadedStrings #-}

module PluginCatalogServer.Auth
  ( hashPassword
  , verifyPassword
  , generateSessionToken
  ) where

import Crypto.KDF.PBKDF2 (Parameters (..), fastPBKDF2_SHA256)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Text.Read (readMaybe)

hashPassword :: Text -> IO Text
hashPassword password = do
  salt <- (getRandomBytes 16 :: IO BS.ByteString)
  let iters = 200000
      params = Parameters {iterCounts = iters, outputLength = 32}
      dk = fastPBKDF2_SHA256 params (TE.encodeUtf8 password) salt :: BS.ByteString
  pure $
    T.intercalate
      "$"
      [ "pbkdf2_sha256"
      , T.pack (show iters)
      , TE.decodeUtf8 (B64.encode salt)
      , TE.decodeUtf8 (B64.encode dk)
      ]

verifyPassword :: Text -> Text -> Bool
verifyPassword password stored =
  case T.splitOn "$" stored of
    [alg, itTxt, saltTxt, hashTxt] | alg == "pbkdf2_sha256" ->
      case (readMaybe (T.unpack itTxt), B64.decode (TE.encodeUtf8 saltTxt), B64.decode (TE.encodeUtf8 hashTxt)) of
        (Just iters, Right salt, Right expected) ->
          let params = Parameters {iterCounts = iters, outputLength = BS.length expected}
              actual = fastPBKDF2_SHA256 params (TE.encodeUtf8 password) salt :: BS.ByteString
           in actual == expected
        _ -> False
    _ -> False

generateSessionToken :: IO Text
generateSessionToken = do
  token <- (getRandomBytes 32 :: IO BS.ByteString)
  pure (TE.decodeUtf8 (B64.encode token))
