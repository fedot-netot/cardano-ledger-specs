{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}

module Shelley.Spec.Ledger.OCert
  ( OCert (..),
    OCertEnv (..),
    OCertSignable (..),
    ocertToSignable,
    currentIssueNo,
    KESPeriod (..),
    slotsPerKESPeriod,
    kesPeriod,
  )
where

import Cardano.Binary (FromCBOR (..), ToCBOR (..), toCBOR)
import qualified Cardano.Crypto.DSIGN as DSIGN
import qualified Cardano.Crypto.KES as KES
import Cardano.Crypto.Util (SignableRepresentation (..))
import Cardano.Ledger.Crypto (KES)
import Cardano.Ledger.Era
import Cardano.Prelude (NoUnexpectedThunks (..))
import Control.Monad.Trans.Reader (asks)
import qualified Data.ByteString.Builder as BS
import qualified Data.ByteString.Builder.Extra as BS
import Data.Functor ((<&>))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import GHC.Generics (Generic)
import Quiet
import Shelley.Spec.Ledger.BaseTypes
import Shelley.Spec.Ledger.Keys
  ( KeyHash,
    KeyRole (..),
    SignedDSIGN,
    VerKeyKES,
    coerceKeyRole,
    decodeSignedDSIGN,
    decodeVerKeyKES,
    encodeSignedDSIGN,
    encodeVerKeyKES,
  )
import Shelley.Spec.Ledger.Serialization
  ( CBORGroup (..),
    FromCBORGroup (..),
    ToCBORGroup (..),
    runByteBuilder,
  )
import Shelley.Spec.Ledger.Slot (SlotNo (..))

data OCertEnv era = OCertEnv
  { ocertEnvStPools :: Set (KeyHash 'StakePool era),
    ocertEnvGenDelegs :: Set (KeyHash 'GenesisDelegate era)
  }
  deriving (Show, Eq)

currentIssueNo ::
  OCertEnv era ->
  (Map (KeyHash 'BlockIssuer era) Word64) ->
  -- | Pool hash
  KeyHash 'BlockIssuer era ->
  Maybe Word64
currentIssueNo (OCertEnv stPools genDelegs) cs hk
  | Map.member hk cs = Map.lookup hk cs
  | Set.member (coerceKeyRole hk) stPools = Just 0
  | Set.member (coerceKeyRole hk) genDelegs = Just 0
  | otherwise = Nothing

newtype KESPeriod = KESPeriod {unKESPeriod :: Word}
  deriving (Eq, Generic, Ord, NoUnexpectedThunks, FromCBOR, ToCBOR)
  deriving (Show) via Quiet KESPeriod

data OCert era = OCert
  { -- | The operational hot key
    ocertVkHot :: !(VerKeyKES era),
    -- | counter
    ocertN :: !Word64,
    -- | Start of key evolving signature period
    ocertKESPeriod :: !KESPeriod,
    -- | Signature of block operational certificate content
    ocertSigma :: !(SignedDSIGN era (OCertSignable era))
  }
  deriving (Generic)
  deriving (ToCBOR) via (CBORGroup (OCert era))

deriving instance Era era => Eq (OCert era)

deriving instance Era era => Show (OCert era)

instance Era era => NoUnexpectedThunks (OCert era)

instance
  (Era era) =>
  ToCBORGroup (OCert era)
  where
  toCBORGroup ocert =
    encodeVerKeyKES (ocertVkHot ocert)
      <> toCBOR (ocertN ocert)
      <> toCBOR (ocertKESPeriod ocert)
      <> encodeSignedDSIGN (ocertSigma ocert)
  encodedGroupSizeExpr size proxy =
    KES.encodedVerKeyKESSizeExpr (ocertVkHot <$> proxy)
      + encodedSizeExpr size ((toWord . ocertN) <$> proxy)
      + encodedSizeExpr size ((\(KESPeriod p) -> p) . ocertKESPeriod <$> proxy)
      + DSIGN.encodedSigDSIGNSizeExpr (((\(DSIGN.SignedDSIGN sig) -> sig) . ocertSigma) <$> proxy)
    where
      toWord :: Word64 -> Word
      toWord = fromIntegral

  listLen _ = 4
  listLenBound _ = 4

instance
  (Era era) =>
  FromCBORGroup (OCert era)
  where
  fromCBORGroup =
    OCert
      <$> decodeVerKeyKES
      <*> fromCBOR
      <*> fromCBOR
      <*> decodeSignedDSIGN

kesPeriod :: SlotNo -> ShelleyBase KESPeriod
kesPeriod (SlotNo s) =
  asks slotsPerKESPeriod <&> \spkp ->
    if spkp == 0
      then error "kesPeriod: slots per KES period was set to zero"
      else KESPeriod . fromIntegral $ s `div` spkp

-- | Signable part of an operational certificate
data OCertSignable era
  = OCertSignable !(VerKeyKES era) !Word64 !KESPeriod

instance
  forall era.
  Era era =>
  SignableRepresentation (OCertSignable era)
  where
  getSignableRepresentation (OCertSignable vk counter period) =
    runByteBuilder
      ( fromIntegral $
          KES.sizeVerKeyKES (Proxy @(KES (Crypto era)))
            + 8
            + 8
      )
      $ BS.byteStringCopy (KES.rawSerialiseVerKeyKES vk)
        <> BS.word64BE counter
        <> BS.word64BE (fromIntegral $ unKESPeriod period)

-- | Extract the signable part of an operational certificate (for verification)
ocertToSignable :: OCert era -> OCertSignable era
ocertToSignable OCert {ocertVkHot, ocertN, ocertKESPeriod} =
  OCertSignable ocertVkHot ocertN ocertKESPeriod
