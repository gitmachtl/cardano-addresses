{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_HADDOCK prune #-}

module Cardano.Address
    ( -- * Address
      Address
    , PaymentAddress (..)
    , DelegationAddress (..)
    , PointerAddress (..)
    , ChainPointer (..)
    , unsafeMkAddress
    , unAddress

      -- * Conversion From / To Text
    , base58
    , fromBase58
    , bech32
    , bech32With
    , fromBech32

      -- Internal / Network Discrimination
    , HasNetworkDiscriminant (..)
    , AddressDiscrimination (..)
    , NetworkTag (..)
    , invariantSize
    , invariantNetworkTag
    ) where

import Prelude

import Cardano.Address.Derivation
    ( Depth (..), XPub )
import Cardano.Codec.Cbor
    ( decodeAddress, deserialiseCbor )
import Codec.Binary.Bech32
    ( HumanReadablePart )
import Codec.Binary.Encoding
    ( AbstractEncoding (..), encode )
import Control.DeepSeq
    ( NFData )
import Control.Monad
    ( (<=<) )
import Data.ByteString
    ( ByteString )
import Data.Either.Extra
    ( eitherToMaybe )
import Data.Text
    ( Text )
import Data.Word
    ( Word32, Word8 )
import GHC.Generics
    ( Generic )
import GHC.Stack
    ( HasCallStack )
import Numeric.Natural
    ( Natural )

import qualified Codec.Binary.Bech32.TH as Bech32
import qualified Codec.Binary.Encoding as E
import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as T

-- | An 'Address' type representing 'Cardano' addresses. Internals are
-- irrevelant to the user.
--
-- @since 1.0.0
newtype Address = Address
    { unAddress :: ByteString
    } deriving stock (Generic, Show, Eq, Ord)
instance NFData Address

-- Unsafe constructor for easily lifting bytes inside an 'Address'.
--
-- /!\ Use at your own risks.
unsafeMkAddress :: ByteString -> Address
unsafeMkAddress = Address

-- | Encode an 'Address' to a base58 'Text'.
--
-- @since 1.0.0
base58 :: Address -> Text
base58 = T.decodeUtf8 . encode EBase58 . unAddress

-- | Decode a base58-encoded 'Text' into an 'Address'
--
-- @since 1.0.0
fromBase58 :: Text -> Maybe Address
fromBase58 =
    deserialiseCbor (unsafeMkAddress <$> decodeAddress)
   <=<
    eitherToMaybe . E.fromBase58 . T.encodeUtf8

-- | Encode an 'Address' to bech32 'Text', using @addr@ as a human readable prefix.
--
-- @since 1.0.0
bech32 :: Address -> Text
bech32 = bech32With hrp
  where
    hrp = [Bech32.humanReadablePart|addr|]

-- | Encode an 'Address' to bech32 'Text', using a specified human readable prefix.
--
-- @since 2.0.0
bech32With :: HumanReadablePart -> Address -> Text
bech32With hrp = T.decodeUtf8 . encode (EBech32 hrp) . unAddress

-- | Decode a bech32-encoded  'Text' into an 'Address'
--
-- @since 1.0.0
fromBech32 :: Text -> Maybe Address
fromBech32 = eitherToMaybe . fmap unsafeMkAddress. E.fromBech32 . T.encodeUtf8

-- | Encoding of addresses for certain key types and backend targets.
--
-- @since 1.0.0
class HasNetworkDiscriminant key => PaymentAddress key where
    -- | Convert a public key to a payment 'Address' valid for the given
    -- network discrimination.
    --
    -- @since 1.0.0
    paymentAddress :: NetworkDiscriminant key -> key 'AddressK XPub -> Address

-- | Encoding of delegation addresses for certain key types and backend targets.
--
-- @since 2.0.0
class PaymentAddress key
    => DelegationAddress key where
    -- | Convert a public key and a staking key to a delegation 'Address' valid
    -- for the given network discrimination. Funds sent to this address will be
    -- delegated according to the delegation settings attached to the delegation
    -- key.
    --
    -- @since 2.0.0
    delegationAddress
        :: NetworkDiscriminant key
        ->  key 'AddressK XPub
            -- ^ Payment key
        ->  key 'StakingK XPub
            -- ^ Staking key
        -> Address

-- | A 'ChainPointer' type representing location of some object
-- in the blockchain (eg., staking certificate). This can be achieved
-- unambiguously by specifying slot number, transaction index and the index
-- in the object list (eg., certification list).
-- For staking certificates, alternatively,  the staking key can be used and
-- then 'DelegationAddress' can be used.
--
-- @since 2.0.0
data ChainPointer = ChainPointer
    { slotNum :: Natural
      -- ^ Pointer to the slot
    , transactionIndex :: Natural
      -- ^ transaction index
    , outputIndex :: Natural
      -- ^ output list index
    } deriving stock (Generic, Show, Eq, Ord)
instance NFData ChainPointer

-- | Encoding of pointer addresses for payment key type, pointer to staking
-- certificate in the blockchain and backend targets.
--
-- @since 2.0.0
class PaymentAddress key
    => PointerAddress key where
    -- | Convert a payment public key and a pointer to staking key in the
    -- blockchain to a delegation 'Address' valid for the given network
    -- discrimination. Funds sent to this address will be delegated according to
    -- the delegation settings attached to the delegation key located by
    -- 'ChainPointer'.
    --
    -- @since 2.0.0
    pointerAddress
        :: NetworkDiscriminant key
        ->  key 'AddressK XPub
            -- ^ Payment key
        ->  ChainPointer
            -- ^ Pointer to locate staking key in blockchain
        -> Address

class HasNetworkDiscriminant (key :: Depth -> * -> *) where
    type NetworkDiscriminant key :: *

    addressDiscrimination :: NetworkDiscriminant key -> AddressDiscrimination
    networkTag :: NetworkDiscriminant key -> NetworkTag

-- Magic constant associated with a given network. This is mainly used in two
-- places:
--
-- (1) In 'Address' payloads, to discriminate addresses between networks.
-- (2) At the network-level, when doing handshake with nodes.
newtype NetworkTag
    = NetworkTag { unNetworkTag :: Word32 }
    deriving (Generic, Show, Eq)
instance NFData NetworkTag

-- Describe requirements for address discrimination on the Byron era.
data AddressDiscrimination
    = RequiresNetworkTag
    | RequiresNoTag
    deriving (Generic, Show, Eq)
instance NFData AddressDiscrimination

invariantSize :: HasCallStack => Int -> ByteString -> ByteString
invariantSize expectedLength bytes
    | BS.length bytes == expectedLength = bytes
    | otherwise = error
      $ "length was "
      ++ show (BS.length bytes)
      ++ ", but expected to be "
      ++ (show expectedLength)

invariantNetworkTag :: HasCallStack => Word32 -> NetworkTag -> Word8
invariantNetworkTag limit (NetworkTag num)
    | num < limit = fromIntegral num
    | otherwise = error
      $ "network tag was "
      ++ show num
      ++ ", but expected to be less than "
      ++ show limit
