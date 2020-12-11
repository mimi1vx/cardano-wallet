{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Wallet.Primitive.SlottingSpec
    ( spec
    ) where

import Prelude

import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Data.Tracer
    ( HasSeverityAnnotation (..) )
import Cardano.Slotting.Slot
    ( SlotNo (..) )
import Cardano.Wallet.Gen
    ( genActiveSlotCoefficient, shrinkActiveSlotCoefficient )
import Cardano.Wallet.Primitive.Slotting
    ( PastHorizonException
    , Qry
    , TimeInterpreterLog (..)
    , epochOf
    , expectAndThrowFailures
    , firstSlotInEpoch
    , interpretQuery
    , mkSingleEraInterpreter
    , mkTimeInterpreter
    , neverFails
    , slotRangeFromTimeRange
    , slotToUTCTime
    , timeOfEpoch
    , unsafeExtendSafeZone
    )
import Cardano.Wallet.Primitive.Slotting.Legacy
    ( SlotParameters (..)
    , flatSlot
    , fromFlatSlot
    , slotParams
    , slotRangeFromTimeRange'
    , slotStartTime
    )
import Cardano.Wallet.Primitive.Types
    ( ActiveSlotCoefficient
    , EpochLength (..)
    , EpochNo (..)
    , Range (..)
    , SlotId (..)
    , SlotLength (..)
    , SlottingParameters (..)
    , StartTime (..)
    )
import Cardano.Wallet.Primitive.Types.Hash
    ( Hash (..) )
import Control.Monad.Trans.Except
    ( runExceptT )
import Data.Either
    ( isLeft, isRight )
import Data.Functor.Identity
    ( runIdentity )
import Data.Generics.Internal.VL.Lens
    ( (^.) )
import Data.Quantity
    ( Quantity (..) )
import Data.Time
    ( UTCTime )
import Data.Time.Clock
    ( getCurrentTime )
import Data.Word
    ( Word32 )
import Ouroboros.Consensus.BlockchainTime.WallClock.Types
    ( RelativeTime (..), mkSlotLength )
import Ouroboros.Consensus.Config.SecurityParam
    ( SecurityParam (..) )
import Ouroboros.Consensus.Util.Counting
    ( exactlyOne )
import Test.Hspec
    ( Spec, describe, it, parallel, runIO, shouldBe, shouldSatisfy )
import Test.QuickCheck
    ( Arbitrary (..), Property, choose, property, withMaxSuccess, (===) )
import Test.QuickCheck.Arbitrary.Generic
    ( genericArbitrary, genericShrink )
import Test.Utils.Time
    ( genUniformTime )
import Test.Utils.Trace
    ( captureLogging )
import UnliftIO.Exception
    ( try )

import qualified Cardano.Slotting.Slot as Cardano
import qualified Ouroboros.Consensus.HardFork.History.EraParams as HF
import qualified Ouroboros.Consensus.HardFork.History.Qry as HF
import qualified Ouroboros.Consensus.HardFork.History.Summary as HF

spec :: Spec
spec = do
    describe "slotting" $ do
        parallel $ describe "runQuery NEW mkSingleEraInterpreter == OLD . fromFlatSlot" $ do
            it "epochOf and epochNumber"
                $  property $ legacySlottingTest (\_ s -> epochNumber s) epochOf

            it "slotToUTCTime and slotStartTime"
                $ property $ legacySlottingTest slotStartTime slotToUTCTime

            it "slotRangeFromTimeRange and slotRangeFromTimeRange'"
                $ withMaxSuccess 10000 $ property $ \t0 sp timeRange -> do
                    -- NOTE: The old impementation breaks for large times /
                    -- slotNos. After only generating SlotLengths of 1s or
                    -- bigger, it should hopefully always work.
                    let res = runIdentity $ interpretQuery
                            (mkSingleEraInterpreter t0 sp)
                            (slotRangeFromTimeRange timeRange)

                    let legacy = slotRangeFromTimeRange' (slotParams t0 sp) timeRange

                    let el = sp ^. #getEpochLength
                    let res' = fmap (fromFlatSlot el . unSlotNo) <$> res
                    res' === legacy

            it "(firstSlotInEpoch e) vs (SlotId e 0) "
                $ withMaxSuccess 10000 $ property $ \t0 sp e -> do
                    let res = runIdentity $ interpretQuery
                            (mkSingleEraInterpreter t0 sp)
                            (firstSlotInEpoch e)
                    let legacy = SlotNo $ flatSlot (sp ^. #getEpochLength) $ SlotId e 0

                    res === legacy

        it "endTimeOfEpoch e == (slotToUTCTime =<< firstSlotInEpoch (e + 1)) \
           \ (always true using mkSingleEraInterpreter)"
            $ withMaxSuccess 10000 $ property $ \t0 sp e -> do
                let run :: Qry a -> a
                    run = runIdentity . interpretQuery
                        (mkSingleEraInterpreter t0 sp)

                    endTimeOfEpoch :: EpochNo -> Qry UTCTime
                    endTimeOfEpoch = fmap snd . timeOfEpoch

                run (endTimeOfEpoch e)
                    === run (slotToUTCTime =<< firstSlotInEpoch (e + 1))

        describe "TimeInterpreter conversions beyond the safe zone" $ do

            startTime <- runIO $ StartTime <$> getCurrentTime
            let failingQry = slotToUTCTime (SlotNo 100000)

            it "normally fails and logs failures as Notice" $ do
                (logs, res) <- captureLogging $ \tr -> do
                    let ti = mkTimeInterpreter tr startTime (pure forkInterpreter)
                    runExceptT $ interpretQuery ti failingQry

                res `shouldSatisfy` isLeft
                logs `shouldSatisfy` (\case
                    [MsgInterpreterPastHorizon Nothing _] -> True
                    _ -> False)
                getSeverityAnnotation (head logs) `shouldBe` Notice

            it "(neverFails \"because\" ti) logs failures as Error" $ do
                (logs, res) <- captureLogging $ \tr -> do
                    let ti = neverFails "because" $
                            mkTimeInterpreter tr startTime $
                            pure forkInterpreter
                    try @IO @PastHorizonException $ interpretQuery ti failingQry

                res `shouldSatisfy` isLeft
                logs `shouldSatisfy` (\case
                    [MsgInterpreterPastHorizon (Just "because") _] -> True
                    _ -> False)
                getSeverityAnnotation (head logs) `shouldBe` Error

            it "(unsafeExtendSafeZone ti) doesn't fail nor log" $ do
                (logs, res) <- captureLogging $ \tr -> do
                    let ti = unsafeExtendSafeZone $
                            mkTimeInterpreter tr startTime $
                            pure forkInterpreter
                    try @IO @PastHorizonException $ interpretQuery ti failingQry

                res `shouldSatisfy` isRight
                logs `shouldBe` []

            it "(expectAndThrowFailures ti) fails and logs as Notice" $ do
                (logs, res) <- captureLogging $ \tr -> do
                    let ti = expectAndThrowFailures $
                            mkTimeInterpreter tr startTime $
                            pure forkInterpreter
                    try @IO @PastHorizonException $ interpretQuery ti failingQry

                res `shouldSatisfy` isLeft
                logs `shouldSatisfy` (\case
                    [MsgInterpreterPastHorizon Nothing _] -> True
                    _ -> False)
                getSeverityAnnotation (head logs) `shouldBe` Notice
  where
    forkInterpreter =
        let
            start = HF.initBound
            end = HF.Bound
                    (RelativeTime 20)
                    (SlotNo 20)
                    (Cardano.EpochNo 1)

            era1Params = HF.defaultEraParams (SecurityParam 2) (mkSlotLength 1)
            summary = HF.summaryWithExactly $ exactlyOne $
                HF.EraSummary start (HF.EraEnd end) era1Params
        in HF.mkInterpreter summary

legacySlottingTest
    :: (Eq a, Show a)
    => (SlotParameters -> SlotId -> a)
    -> (SlotNo -> Qry a)
    -> StartTime
    -> SlottingParameters
    -> SlotNo
    -> Property
legacySlottingTest legacyImpl newImpl t0 sp slotNo = withMaxSuccess 10000 $ do
    let res = runIdentity $ interpretQuery
            (mkSingleEraInterpreter t0 sp)
            (newImpl slotNo)
    let legacy = legacyImpl (slotParams t0 sp) $ fromFlatSlot
            (sp ^. #getEpochLength)
            (unSlotNo slotNo)
    res === legacy


{-------------------------------------------------------------------------------
                              Arbitrary instances
-------------------------------------------------------------------------------}

instance Arbitrary SlotNo where
    -- Don't generate /too/ large slots
    arbitrary = SlotNo . fromIntegral <$> (arbitrary @Word32)
    shrink (SlotNo x) = map SlotNo $ shrink x

instance Arbitrary EpochNo where
    -- Don't generate /too/ large numbers
    arbitrary = EpochNo . fromIntegral <$> (arbitrary @Word32)
    shrink _ = []

instance Arbitrary SlottingParameters where
    arbitrary = genericArbitrary
    shrink = genericShrink

instance Arbitrary SlotLength where
    arbitrary = SlotLength . fromRational . toRational <$> choose (1,10::Double)
    shrink _ = []

instance Arbitrary (Hash "Genesis") where
    arbitrary = return $ Hash "Genesis Hash"
    shrink _ = []

instance Arbitrary StartTime where
    arbitrary = StartTime <$> genUniformTime
    shrink _ = []

instance Arbitrary EpochLength where
    arbitrary = EpochLength <$> choose (2,100000)
    shrink _ = []

instance Arbitrary ActiveSlotCoefficient where
    arbitrary = genActiveSlotCoefficient
    shrink = shrinkActiveSlotCoefficient

instance Arbitrary (Quantity "block" Word32) where
    arbitrary = Quantity <$> choose (1,100000)
    shrink (Quantity x) = map Quantity $ shrink x

instance (Arbitrary a, Ord a) => Arbitrary (Range a) where
    arbitrary =
        makeRangeValid . uncurry Range <$> arbitrary
    shrink (Range p q) =
        makeRangeValid . uncurry Range <$> shrink (p, q)

-- Ensures that the start of a range is not greater than its end.
makeRangeValid :: Ord a => Range a -> Range a
makeRangeValid = \case
    Range (Just p) (Just q) -> Range (Just $ min p q) (Just $ max p q)
    r -> r

instance Arbitrary UTCTime where
    arbitrary = genUniformTime
