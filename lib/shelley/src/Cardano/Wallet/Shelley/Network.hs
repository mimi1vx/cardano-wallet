{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Copyright: © 2020 IOHK
-- License: Apache-2.0
--
-- Network Layer for talking to Haskell re-written nodes.
--
-- Good to read before / additional resources:
--
-- - Module's documentation in `ouroboros-network/typed-protocols/src/Network/TypedProtocols.hs`
-- - Data Diffusion and Peer Networking in Shelley (see: https://raw.githubusercontent.com/wiki/input-output-hk/cardano-wallet/data_diffusion_and_peer_networking_in_shelley.pdf)
--     - In particular sections 4.1, 4.2, 4.6 and 4.8
module Cardano.Wallet.Shelley.Network
    ( -- * Top-Level Interface
      pattern Cursor
    , withNetworkLayer

    , Observer (query,startObserving,stopObserving)
    , newObserver
    , ObserverLog (..)

      -- * Logging
    , NetworkLayerLog (..)
    ) where

import Prelude

import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Data.Tracer
    ( HasPrivacyAnnotation (..), HasSeverityAnnotation (..) )
import Cardano.Wallet.Byron.Compatibility
    ( byronCodecConfig, protocolParametersFromUpdateState )
import Cardano.Wallet.Logging
    ( BracketLog, bracketTracer )
import Cardano.Wallet.Network
    ( Cursor
    , ErrNetworkUnavailable (..)
    , ErrPostTx (..)
    , NetworkLayer (..)
    , mapCursor
    )
import Cardano.Wallet.Primitive.Slotting
    ( TimeInterpreter, TimeInterpreterLog, mkTimeInterpreter )
import Cardano.Wallet.Shelley.Compatibility
    ( AnyCardanoEra (..)
    , CardanoEra (..)
    , StandardCrypto
    , fromCardanoHash
    , fromChainHash
    , fromNonMyopicMemberRewards
    , fromPoolDistr
    , fromShelleyCoin
    , fromShelleyPParams
    , fromStakeCredential
    , fromTip
    , fromTip'
    , optimumNumberOfPools
    , toCardanoEra
    , toPoint
    , toShelleyCoin
    , toStakeCredential
    , unsealShelleyTx
    )
import Control.Applicative
    ( liftA3 )
import Control.Concurrent
    ( ThreadId )
import Control.Concurrent.Chan
    ( Chan, dupChan, newChan, readChan, writeChan )
import Control.Monad
    ( forever, unless, void, when, (>=>) )
import Control.Monad.Class.MonadAsync
    ( MonadAsync )
import Control.Monad.Class.MonadST
    ( MonadST )
import Control.Monad.Class.MonadSTM
    ( MonadSTM
    , TMVar
    , TQueue
    , TVar
    , atomically
    , isEmptyTMVar
    , modifyTVar'
    , newEmptyTMVar
    , newTMVarIO
    , newTQueue
    , newTVar
    , putTMVar
    , putTMVar
    , readTMVar
    , readTVar
    , takeTMVar
    , writeTVar
    )
import Control.Monad.Class.MonadThrow
    ( MonadThrow )
import Control.Monad.Class.MonadTimer
    ( MonadTimer, threadDelay )
import Control.Monad.IO.Class
    ( MonadIO, liftIO )
import Control.Monad.Trans.Except
    ( ExceptT (..), throwE, withExceptT )
import Control.Retry
    ( RetryPolicyM, RetryStatus (..), capDelay, fibonacciBackoff, recovering )
import Control.Tracer
    ( Tracer, contramap, nullTracer, traceWith )
import Data.ByteArray.Encoding
    ( Base (..), convertToBase )
import Data.ByteString.Lazy
    ( ByteString )
import Data.Either.Extra
    ( eitherToMaybe )
import Data.Function
    ( (&) )
import Data.List
    ( isInfixOf )
import Data.Map
    ( Map, (!) )
import Data.Maybe
    ( fromMaybe )
import Data.Proxy
    ( Proxy (..) )
import Data.Quantity
    ( Quantity (..) )
import Data.Set
    ( Set )
import Data.Text
    ( Text )
import Data.Text.Class
    ( ToText (..) )
import Data.Time.Clock
    ( NominalDiffTime, diffUTCTime, getCurrentTime )
import Data.Void
    ( Void )
import Fmt
    ( Buildable (..), fmt, listF, mapF, pretty )
import GHC.Stack
    ( HasCallStack )
import Network.Mux
    ( MuxError (..), MuxErrorType (..), WithMuxBearer (..) )
import Ouroboros.Consensus.Cardano
    ( CardanoBlock )
import Ouroboros.Consensus.Cardano.Block
    ( CardanoApplyTxErr
    , CardanoEras
    , CodecConfig (..)
    , GenTx (..)
    , Query (..)
    )
import Ouroboros.Consensus.HardFork.Combinator
    ( QueryAnytime (..), QueryHardFork (..) )
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( MismatchEraInfo )
import Ouroboros.Consensus.HardFork.History.Qry
    ( Interpreter, PastHorizonException (..) )
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (..) )
import Ouroboros.Consensus.Network.NodeToClient
    ( ClientCodecs, Codecs' (..), DefaultCodecs, clientCodecs, defaultCodecs )
import Ouroboros.Consensus.Node.NetworkProtocolVersion
    ( HasNetworkProtocolVersion (..), SupportedNetworkProtocolVersion (..) )
import Ouroboros.Consensus.Shelley.Ledger.Config
    ( CodecConfig (..) )
import Ouroboros.Network.Block
    ( Point
    , SlotNo (..)
    , Tip (..)
    , blockPoint
    , castTip
    , genesisPoint
    , getPoint
    , getTipPoint
    , pointHash
    , pointSlot
    )
import Ouroboros.Network.Client.Wallet
    ( ChainSyncCmd (..)
    , ChainSyncLog (..)
    , LocalStateQueryCmd (..)
    , LocalTxSubmissionCmd (..)
    , chainSyncFollowTip
    , chainSyncWithBlocks
    , localStateQuery
    , localTxSubmission
    , mapChainSyncLog
    , send
    )
import Ouroboros.Network.CodecCBORTerm
    ( CodecCBORTerm )
import Ouroboros.Network.Driver.Simple
    ( TraceSendRecv, runPeer, runPipelinedPeer )
import Ouroboros.Network.Mux
    ( MuxMode (..)
    , MuxPeer (..)
    , OuroborosApplication (..)
    , RunMiniProtocol (..)
    )
import Ouroboros.Network.NodeToClient
    ( ConnectionId (..)
    , Handshake
    , LocalAddress
    , NetworkConnectTracers (..)
    , NodeToClientProtocols (..)
    , NodeToClientVersion (..)
    , NodeToClientVersionData (..)
    , connectTo
    , localSnocket
    , nodeToClientProtocols
    , withIOManager
    )
import Ouroboros.Network.Point
    ( WithOrigin (..), fromWithOrigin )
import Ouroboros.Network.Protocol.ChainSync.Client
    ( chainSyncClientPeer )
import Ouroboros.Network.Protocol.ChainSync.ClientPipelined
    ( chainSyncClientPeerPipelined )
import Ouroboros.Network.Protocol.Handshake.Version
    ( simpleSingletonVersions )
import Ouroboros.Network.Protocol.LocalStateQuery.Client
    ( localStateQueryClientPeer )
import Ouroboros.Network.Protocol.LocalStateQuery.Type
    ( AcquireFailure, LocalStateQuery )
import Ouroboros.Network.Protocol.LocalTxSubmission.Client
    ( localTxSubmissionClientPeer )
import Ouroboros.Network.Protocol.LocalTxSubmission.Type
    ( LocalTxSubmission, SubmitResult (..) )
import System.IO.Error
    ( isDoesNotExistError )
import UnliftIO.Async
    ( Async, async, asyncThreadId, cancel, link )
import UnliftIO.Exception
    ( Handler (..), IOException )

import qualified Cardano.Wallet.Primitive.Types as W
import qualified Cardano.Wallet.Primitive.Types.Coin as W
import qualified Cardano.Wallet.Primitive.Types.Hash as W
import qualified Cardano.Wallet.Primitive.Types.RewardAccount as W
import qualified Cardano.Wallet.Primitive.Types.Tx as W
import qualified Codec.CBOR.Term as CBOR
import qualified Control.Monad.Catch as E
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Ouroboros.Consensus.Byron.Ledger as Byron
import qualified Ouroboros.Consensus.Shelley.Ledger as Shelley
import qualified Ouroboros.Network.Point as Point
import qualified Shelley.Spec.Ledger.API as SL
import qualified Shelley.Spec.Ledger.LedgerState as SL

{- HLINT ignore "Use readTVarIO" -}
{- HLINT ignore "Use newTVarIO" -}
{- HLINT ignore "Use newEmptyTMVarIO" -}

-- | Network layer cursor for Shelley. Mostly useless since the protocol itself is
-- stateful and the node's keep track of the associated connection's cursor.
data instance Cursor = Cursor
    (Async ())
    (Point (CardanoBlock StandardCrypto))
    (TQueue IO (ChainSyncCmd (CardanoBlock StandardCrypto) IO))

-- | Create an instance of the network layer
withNetworkLayer
    :: HasCallStack
    => Tracer IO NetworkLayerLog
        -- ^ Logging of network layer startup
    -> W.NetworkParameters
        -- ^ Initial blockchain parameters
    -> FilePath
        -- ^ Socket for communicating with the node
    -> (NodeToClientVersionData, CodecCBORTerm Text NodeToClientVersionData)
        -- ^ Codecs for the node's client
    -> (NetworkLayer IO (CardanoBlock StandardCrypto) -> IO a)
        -- ^ Callback function with the network layer
    -> IO a
withNetworkLayer tr np addrInfo (versionData, _) action = do
    -- NOTE: We keep client connections running for accessing the node tip,
    -- submitting transactions, querying parameters and delegations/rewards.
    --
    -- It is safe to retry when the connection is lost here because this client
    -- doesn't really do anything but sending messages to get the node's tip. It
    -- doesn't rely on the intersection to be up-to-date.
    let handlers = retryOnConnectionLost tr

    queryRewardQ <- connectDelegationRewardsClient handlers

    (nodeTipChan, protocolParamsVar, interpreterVar, localTxSubmissionQ) <-
        connectNodeTipClient handlers

    (rewardsObserver, refreshRewards) <-
        newRewardBalanceFetcher tr gp queryRewardQ

    -- We store the last known tip and last known era in TVars. The only writer
    -- of this TVar is 'updateNodeTip' just below, but many reads from them in
    -- the network layer.
    nodeTipVar <- atomically $ newTVar TipGenesis
    nodeEraVar <- atomically $ newTVar (AnyCardanoEra ByronEra)

    let updateNodeTip = do
            (maybeEra, tip) <- readChan nodeTipChan
            atomically $ writeTVar nodeTipVar tip
            -- If the node just rolled back, we'll get only a tip and no era and
            -- we'll only update the era on the next roll forward. So it may
            -- happen that for a short time, there's an era mismatch if we make
            -- a request right after a rollback that crossed two eras.
            --
            -- Worse that can happen though is the query being invalid or in the
            -- wrong era which is handled everywhere already.
            era <- case maybeEra of
                Just era -> era <$ atomically (writeTVar nodeEraVar era)
                Nothing  -> atomically $ readTVar nodeEraVar
            refreshRewards (era, tip)
    link =<< async (forever updateNodeTip)

    action $ NetworkLayer
            { currentNodeTip = liftIO $ _currentNodeTip nodeTipVar
            , currentNodeEra = _currentNodeEra nodeEraVar
            , watchNodeTip = _watchNodeTip nodeTipChan
            , nextBlocks = _nextBlocks
            , initCursor = _initCursor
            , destroyCursor = _destroyCursor
            , cursorSlotNo = _cursorSlotNo
            , getProtocolParameters = atomically $ readTVar protocolParamsVar
            , postTx = _postTx localTxSubmissionQ nodeEraVar
            , stakeDistribution = _stakeDistribution queryRewardQ nodeEraVar
            , getAccountBalance = \k -> liftIO $ do
                -- TODO(#2042): Make wallets call manually, with matching
                -- stopObserving.
                startObserving rewardsObserver k
                coinToQuantity . fromMaybe (W.Coin 0)
                    <$> query rewardsObserver k
            , timeInterpreter = _timeInterpreter interpreterVar
            }
  where
    coinToQuantity (W.Coin x) = Quantity $ fromIntegral x

    gp@W.GenesisParameters
        { getGenesisBlockHash
        , getGenesisBlockDate
        } = W.genesisParameters np
    sp = W.slottingParameters np
    cfg = codecConfig sp

    -- Put if empty, replace if not empty.
    repsertTMVar var x = do
        e <- isEmptyTMVar var
        unless e $ void $ takeTMVar var
        putTMVar var x

    connectNodeTipClient
        :: HasCallStack
        => RetryHandlers
        -> IO ( Chan (Maybe AnyCardanoEra, Tip (CardanoBlock StandardCrypto))
              , TVar IO W.ProtocolParameters
              , TMVar IO (CardanoInterpreter StandardCrypto)
              , TQueue IO (LocalTxSubmissionCmd
                  (GenTx (CardanoBlock StandardCrypto))
                  (CardanoApplyTxErr StandardCrypto)
                  IO)
              )
    connectNodeTipClient handlers = do
        localTxSubmissionQ <- atomically newTQueue
        nodeTipChan <- newChan
        protocolParamsVar <- atomically $ newTVar $ W.protocolParameters np
        interpreterVar <- atomically newEmptyTMVar
        nodeTipClient <- mkTipSyncClient tr np
            localTxSubmissionQ
            (writeChan nodeTipChan)
            (atomically . writeTVar protocolParamsVar)
            (atomically . repsertTMVar interpreterVar)
        link =<< async (connectClient tr handlers nodeTipClient versionData addrInfo)
        pure (nodeTipChan, protocolParamsVar, interpreterVar, localTxSubmissionQ)

    connectDelegationRewardsClient
        :: HasCallStack
        => RetryHandlers
        -> IO (TQueue IO
                (LocalStateQueryCmd (CardanoBlock StandardCrypto) IO))
    connectDelegationRewardsClient handlers = do
        cmdQ <- atomically newTQueue
        let cl = mkDelegationRewardsClient tr cfg cmdQ
        link =<< async (connectClient tr handlers cl versionData addrInfo)
        pure cmdQ

    _initCursor :: HasCallStack => [W.BlockHeader] -> IO Cursor
    _initCursor headers = do
        chainSyncQ <- atomically newTQueue
        client <- mkWalletClient (contramap MsgChainSyncCmd tr) cfg gp chainSyncQ
        let handlers = failOnConnectionLost tr
        thread <- async (connectClient tr handlers client versionData addrInfo)
        link thread
        let points = reverse $ genesisPoint :
                (toPoint getGenesisBlockHash <$> headers)
        let findIt = chainSyncQ `send` CmdFindIntersection points
        traceWith tr $ MsgFindIntersection headers
        res <- findIt
        case res of
            Just intersection -> do
                traceWith tr
                    $ MsgIntersectionFound
                    $ fromChainHash getGenesisBlockHash
                    $ pointHash intersection
                pure $ Cursor thread intersection chainSyncQ
            _ -> fail $ unwords
                [ "initCursor: intersection not found? This can't happen"
                , "because we always give at least the genesis point."
                , "Here are the points we gave: " <> show headers
                ]

    _destroyCursor (Cursor thread _ _) = do
        liftIO $ traceWith tr $ MsgDestroyCursor (asyncThreadId thread)
        cancel thread

    _nextBlocks (Cursor thread _ chainSyncQ) = do
        let toCursor point = Cursor thread point chainSyncQ
        liftIO $ mapCursor toCursor <$> chainSyncQ `send` CmdNextBlocks

    _cursorSlotNo (Cursor _ point _) = do
        fromWithOrigin (SlotNo 0) $ pointSlot point

    _currentNodeTip nodeTipVar =
        fromTip getGenesisBlockHash <$> atomically (readTVar nodeTipVar)

    _currentNodeEra nodeEraVar =
        atomically (readTVar nodeEraVar)

    -- NOTE1: only shelley transactions can be submitted like this, because they
    -- are deserialised as shelley transactions before submitting.
    --
    -- NOTE2: It is not ideal to query the current era again here because we
    -- should in practice use the same era as the one used to construct the
    -- transaction. However, when turning transactions to 'SealedTx', we loose
    -- all form of type-level indicator about the era. The 'SealedTx' type
    -- shouldn't be needed anymore since we've dropped jormungandr, so we could
    -- instead carry a transaction from cardano-api types with proper typing.
    _postTx localTxSubmissionQ nodeEraVar tx = do
        era <- liftIO $ atomically $ readTVar nodeEraVar
        liftIO $ traceWith tr $ MsgPostTx tx
        case era of
            AnyCardanoEra ByronEra ->
                throwE $ ErrPostTxProtocolFailure "Invalid era: Byron"

            AnyCardanoEra ShelleyEra -> do
                let cmd = CmdSubmitTx $ unsealShelleyTx GenTxShelley tx
                result <- liftIO $ localTxSubmissionQ `send` cmd
                case result of
                    SubmitSuccess -> pure ()
                    SubmitFail err -> throwE $ ErrPostTxBadRequest $ T.pack (show err)

            AnyCardanoEra AllegraEra -> do
                let cmd = CmdSubmitTx $ unsealShelleyTx GenTxAllegra tx
                result <- liftIO $ localTxSubmissionQ `send` cmd
                case result of
                    SubmitSuccess -> pure ()
                    SubmitFail err -> throwE $ ErrPostTxBadRequest $ T.pack (show err)

            AnyCardanoEra MaryEra ->
                throwE $ ErrPostTxProtocolFailure "Invalid era: Mary"

    _stakeDistribution queue eraVar bh coin = do
        liftIO $ traceWith tr $ MsgWillQueryRewardsForStake coin

        era <- liftIO $ atomically $ readTVar eraVar
        let pt = toPoint getGenesisBlockHash bh

        mres <- liftA3 (liftA3 W.StakePoolsSummary)
            (getNOpt pt era)
            (queryNonMyopicMemberRewards pt era)
            (queryStakeDistribution pt era)

        -- The result will be Nothing if query occurs during the byron era
        liftIO $ traceWith tr $ MsgFetchStakePoolsData (eitherToMaybe mres)
        case mres of
            Right res@W.StakePoolsSummary{rewards,stake} -> do
                liftIO $ traceWith tr $ MsgFetchStakePoolsDataSummary
                    (Map.size stake)
                    (Map.size rewards)
                return res
            Left{} -> pure $ W.StakePoolsSummary 0 mempty mempty
      where
        handleQueryFailure :: forall e r. Show e => IO (Either e r) -> ExceptT ErrNetworkUnavailable IO r
        handleQueryFailure =
            withExceptT (\e -> ErrNetworkUnreachable $ T.pack $ "Unexpected " ++ show e) . ExceptT

        queryStakeDistribution pt = \case
            AnyCardanoEra ShelleyEra -> do
                let cmd = CmdQueryLocalState pt (QueryIfCurrentShelley Shelley.GetStakeDistribution)
                result <- handleQueryFailure $ timeQryAndLog "GetStakeDistribution" tr
                    (queue `send` cmd)
                return $ fromPoolDistr <$> result

            ________________________ -> do
                let cmd = CmdQueryLocalState pt (QueryIfCurrentAllegra Shelley.GetStakeDistribution)
                result <- handleQueryFailure $ timeQryAndLog "GetStakeDistribution" tr
                    (queue `send` cmd)
                return $ fromPoolDistr <$> result

        getNOpt pt = \case
            AnyCardanoEra ShelleyEra -> do
                let cmd = CmdQueryLocalState pt (QueryIfCurrentShelley Shelley.GetCurrentPParams)
                result <- handleQueryFailure $ timeQryAndLog "GetCurrentPParams" tr
                    (queue `send` cmd)
                return $ optimumNumberOfPools <$> result

            ________________________ -> do
                let cmd = CmdQueryLocalState pt (QueryIfCurrentAllegra Shelley.GetCurrentPParams)
                result <- handleQueryFailure $ timeQryAndLog "GetCurrentPParams" tr
                    (queue `send` cmd)
                return $ optimumNumberOfPools <$> result

        queryNonMyopicMemberRewards pt = \case
            AnyCardanoEra ShelleyEra -> do
                let cmd = CmdQueryLocalState pt (QueryIfCurrentShelley (Shelley.GetNonMyopicMemberRewards stake))
                result <- handleQueryFailure $ timeQryAndLog "GetNonMyopicMemberRewards" tr
                    (queue `send` cmd)
                return $ getRewardMap . fromNonMyopicMemberRewards <$> result

            ________________________ -> do
                let cmd = CmdQueryLocalState pt (QueryIfCurrentAllegra (Shelley.GetNonMyopicMemberRewards stake))
                result <- handleQueryFailure $ timeQryAndLog "GetNonMyopicMemberRewards" tr
                    (queue `send` cmd)
                return $ getRewardMap . fromNonMyopicMemberRewards <$> result
          where
            stake :: Set (Either SL.Coin a)
            stake = Set.singleton $ Left $ toShelleyCoin coin

            fromJustRewards = fromMaybe
                (error "stakeDistribution: requested rewards not included in response")
            getRewardMap =
                fromJustRewards . Map.lookup (Left coin)

    _watchNodeTip nodeTipChan cb = do
        chan <- dupChan nodeTipChan
        let toBlockHeader = fromTip getGenesisBlockHash
        forever $ do
            header <- toBlockHeader . snd <$> readChan chan
            bracketTracer (contramap (MsgWatcherUpdate header) tr) $
                cb header

    _timeInterpreter
        :: HasCallStack
        => TMVar IO (CardanoInterpreter sc)
        -> TimeInterpreter (ExceptT PastHorizonException IO)
    _timeInterpreter var = do
        let readInterpreter = liftIO $ atomically $ readTMVar var
        mkTimeInterpreter (contramap MsgInterpreterLog tr) getGenesisBlockDate readInterpreter

--------------------------------------------------------------------------------
--
-- Network Client

-- | Type representing a network client running two mini-protocols to sync
-- from the chain and, submit transactions.
type NetworkClient m = OuroborosApplication
    'InitiatorMode
        -- Initiator ~ Client (as opposed to Responder / Server)
    LocalAddress
        -- Address type
    ByteString
        -- Concrete representation for bytes string
    m
        -- Underlying monad we run in
    Void
        -- Return type of a network client. Void indicates that the client
        -- never exits.
    Void
        -- Irrelevant for initiator. Return type of 'ResponderMode' application.

-- | Construct a network client with the given communication channel, for the
-- purposes of syncing blocks to a single wallet.
mkWalletClient
    :: (MonadThrow m, MonadST m, MonadTimer m, MonadAsync m)
    => Tracer m (ChainSyncLog Text Text)
    -> CodecConfig (CardanoBlock StandardCrypto)
    -> W.GenesisParameters
        -- ^ Static blockchain parameters
    -> TQueue m (ChainSyncCmd (CardanoBlock StandardCrypto) m)
        -- ^ Communication channel with the ChainSync client
    -> m (NetworkClient m)
mkWalletClient tr cfg gp chainSyncQ = do
    stash <- atomically newTQueue
    pure $ nodeToClientProtocols (const $ return $ NodeToClientProtocols
        { localChainSyncProtocol =
            InitiatorProtocolOnly $ MuxPeerRaw $ \channel ->
                runPipelinedPeer nullTracer (cChainSyncCodec $ codecs cfg) channel
                $ chainSyncClientPeerPipelined
                $ chainSyncWithBlocks tr' (fromTip' gp) chainSyncQ stash

        , localTxSubmissionProtocol =
            doNothingProtocol

        , localStateQueryProtocol =
            doNothingProtocol
        })
        NodeToClientV_5
  where
    tr' = contramap (mapChainSyncLog showB showP) tr
    showB = showP . blockPoint
    showP p = case (getPoint p) of
        Origin -> "Origin"
        At blk -> mconcat
            [ "(slotNo "
            , T.pack $ show $ unSlotNo $ Point.blockPointSlot blk
            , ", "
            , pretty $ fromCardanoHash $ Point.blockPointHash blk
            , ")"
            ]

-- | Construct a network client with the given communication channel, for the
-- purposes of querying delegations and rewards.
mkDelegationRewardsClient
    :: forall m. (MonadThrow m, MonadST m, MonadTimer m)
    => Tracer m NetworkLayerLog
        -- ^ Base trace for underlying protocols
    -> CodecConfig (CardanoBlock StandardCrypto)
    -> TQueue m (LocalStateQueryCmd (CardanoBlock StandardCrypto) m)
        -- ^ Communication channel with the LocalStateQuery client
    -> NetworkClient m
mkDelegationRewardsClient tr cfg queryRewardQ =
    nodeToClientProtocols (const $ return $ NodeToClientProtocols
        { localChainSyncProtocol =
            doNothingProtocol

        , localTxSubmissionProtocol =
            doNothingProtocol

        , localStateQueryProtocol =
            InitiatorProtocolOnly $ MuxPeerRaw
                $ \channel -> runPeer tr' codec channel
                $ localStateQueryClientPeer
                $ localStateQuery queryRewardQ
        })
        NodeToClientV_5
  where
    tr' = contramap (MsgLocalStateQuery DelegationRewardsClient) tr
    codec = cStateQueryCodec (serialisedCodecs cfg)

{-------------------------------------------------------------------------------
                                     Codecs
-------------------------------------------------------------------------------}

-- | The protocol client version. Distinct from the codecs version.
nodeToClientVersion :: NodeToClientVersion
nodeToClientVersion = NodeToClientV_5

codecVersion :: BlockNodeToClientVersion (CardanoBlock StandardCrypto)
codecVersion = verMap ! nodeToClientVersion
    where verMap = supportedNodeToClientVersions (Proxy @(CardanoBlock StandardCrypto))

codecConfig :: W.SlottingParameters -> CodecConfig (CardanoBlock c)
codecConfig sp = CardanoCodecConfig
    (byronCodecConfig sp)
    ShelleyCodecConfig
    ShelleyCodecConfig
    ShelleyCodecConfig

-- | A group of codecs which will deserialise block data.
codecs
    :: MonadST m
    => CodecConfig (CardanoBlock StandardCrypto)
    -> ClientCodecs (CardanoBlock StandardCrypto) m
codecs cfg = clientCodecs cfg codecVersion

-- | A group of codecs which won't deserialise block data. Often only the block
-- headers are needed. It's more efficient and easier not to deserialise.
serialisedCodecs
    :: MonadST m
    => CodecConfig (CardanoBlock StandardCrypto)
    -> DefaultCodecs (CardanoBlock StandardCrypto) m
serialisedCodecs cfg = defaultCodecs cfg codecVersion

{-------------------------------------------------------------------------------
                                     Tip sync
-------------------------------------------------------------------------------}

type CardanoInterpreter sc = Interpreter (CardanoEras sc)

-- | Construct a network client with the given communication channel, for the
-- purpose of:
--
--  * Submitting transactions
--  * Tracking the node tip
--  * Tracking the latest protocol parameters state.
--  * Querying the history interpreter as necessary.
mkTipSyncClient
    :: forall m. (HasCallStack, MonadIO m, MonadThrow m, MonadST m, MonadTimer m)
    => Tracer m NetworkLayerLog
        -- ^ Base trace for underlying protocols
    -> W.NetworkParameters
        -- ^ Initial blockchain parameters
    -> TQueue m
        (LocalTxSubmissionCmd
            (GenTx (CardanoBlock StandardCrypto))
            (CardanoApplyTxErr StandardCrypto)
            m)
        -- ^ Communication channel with the LocalTxSubmission client
    -> ((Maybe AnyCardanoEra, Tip (CardanoBlock StandardCrypto)) -> m ())
        -- ^ Notifier callback for when tip changes
    -> (W.ProtocolParameters -> m ())
        -- ^ Notifier callback for when parameters for tip change.
    -> (CardanoInterpreter StandardCrypto -> m ())
        -- ^ Notifier callback for when time interpreter is updated.
    -> m (NetworkClient m)
mkTipSyncClient tr np localTxSubmissionQ onTipUpdate onPParamsUpdate onInterpreterUpdate = do
    localStateQueryQ <- atomically newTQueue

    (onPParamsUpdate' :: W.ProtocolParameters -> m ()) <-
        debounce $ \pp -> do
            traceWith tr $ MsgProtocolParameters pp
            onPParamsUpdate pp

    let
        queryLocalState
            :: Maybe AnyCardanoEra
            -> Point (CardanoBlock StandardCrypto)
            -> m ()
        queryLocalState Nothing    __ = return ()
        queryLocalState (Just era) pt = do
            mb <- timeQryAndLog "GetEraStart" tr $ localStateQueryQ `send`
                (case era of
                    AnyCardanoEra ShelleyEra ->
                        CmdQueryLocalState pt (QueryAnytimeShelley GetEraStart)
                    ________________________ ->
                        CmdQueryLocalState pt (QueryAnytimeAllegra GetEraStart)
                )

            case era of
                AnyCardanoEra ByronEra -> do
                    st <- timeQryAndLog "GetUpdateInterfaceState" tr $ localStateQueryQ `send`
                        CmdQueryLocalState pt (QueryIfCurrentByron Byron.GetUpdateInterfaceState)
                    sequence (handleParamsUpdate protocolParametersFromUpdateState <$> mb <*> st)
                        >>= handleAcquireFailure

                AnyCardanoEra ShelleyEra -> do
                    pp <- timeQryAndLog "GetCurrentPParams" tr $ localStateQueryQ `send`
                        (CmdQueryLocalState pt (QueryIfCurrentShelley Shelley.GetCurrentPParams))
                    sequence (handleParamsUpdate fromShelleyPParams <$> mb <*> pp)
                        >>= handleAcquireFailure

                ________________________ -> do
                    pp <- timeQryAndLog "GetCurrentPParams" tr $ localStateQueryQ `send`
                        (CmdQueryLocalState pt (QueryIfCurrentAllegra Shelley.GetCurrentPParams))
                    sequence (handleParamsUpdate fromShelleyPParams <$> mb <*> pp)
                        >>= handleAcquireFailure

        handleAcquireFailure
            :: Either AcquireFailure ()
            -> m ()
        handleAcquireFailure = \case
            Right () ->
                pure ()
            Left e ->
                traceWith tr $ MsgLocalStateQueryError TipSyncClient $ show e

        handleParamsUpdate
            :: (Maybe Bound -> p -> W.ProtocolParameters)
            -> (Maybe Bound)
            -> (Either (MismatchEraInfo (CardanoEras StandardCrypto)) p)
            -> m ()
        handleParamsUpdate convert boundM = \case
            Right ls -> do
                onPParamsUpdate' $ convert boundM ls
            Left mismatch -> do
                traceWith tr $ MsgLocalStateQueryEraMismatch mismatch

        queryInterpreter
            :: Point (CardanoBlock StandardCrypto)
            -> m ()
        queryInterpreter pt = do
            res <- localStateQueryQ `send` CmdQueryLocalState pt (QueryHardFork GetInterpreter)
            case res of
                Left (e :: AcquireFailure) ->
                    traceWith tr $ MsgLocalStateQueryError TipSyncClient $ show e
                Right interpreter -> do
                    traceWith tr $ MsgInterpreter interpreter
                    onInterpreterUpdate interpreter

        W.GenesisParameters
             { getGenesisBlockHash
             } = W.genesisParameters np
        cfg = codecConfig (W.slottingParameters np)

    onTipUpdate' <- debounce @_ @m $ \(era, tip') -> do
        -- FIXME: Store / replace / keep track of the era and make it available
        -- for other functions.
        let tip = castTip tip'
        traceWith tr $ MsgNodeTip $
            fromTip getGenesisBlockHash tip
        onTipUpdate (era, tip)
        queryLocalState era (getTipPoint tip)
        -- NOTE: interpeter is updated every block. This is far more often than
        -- necessary.
        queryInterpreter (getTipPoint tip)

    pure $ nodeToClientProtocols (const $ return $ NodeToClientProtocols
        { localChainSyncProtocol =
            let
                codec = cChainSyncCodec $ codecs cfg
            in
            InitiatorProtocolOnly $ MuxPeerRaw
                $ \channel -> runPeer nullTracer codec channel
                $ chainSyncClientPeer
                $ chainSyncFollowTip toCardanoEra (curry onTipUpdate')

        , localTxSubmissionProtocol =
            let
                tr' = contramap MsgTxSubmission tr
                codec = cTxSubmissionCodec $ serialisedCodecs cfg
            in
            InitiatorProtocolOnly $ MuxPeerRaw
                $ \channel -> runPeer tr' codec channel
                $ localTxSubmissionClientPeer
                $ localTxSubmission localTxSubmissionQ

        , localStateQueryProtocol =
            let
                tr' = contramap (MsgLocalStateQuery TipSyncClient) tr
                codec = cStateQueryCodec $ serialisedCodecs cfg
            in
            InitiatorProtocolOnly $ MuxPeerRaw
                $ \channel -> runPeer tr' codec channel
                $ localStateQueryClientPeer
                $ localStateQuery localStateQueryQ
        })
        NodeToClientV_5

-- Reward Account Balances

-- | Monitors values for keys, and allows clients to @query@ them.
--
-- Designed to be used for observing reward balances, where we want to cache the
-- balances of /all/ the wallets' accounts on tip change, and allow wallet
-- workers to @query@ the cache later, often, and whenever they want.
--
-- NOTE: One could imagine replacing @query@ getter with a push-based approach.
data Observer m key value = Observer
    { startObserving :: key -> m ()
    , stopObserving :: key -> m ()
    , query :: key -> m (Maybe value)
    }

newRewardBalanceFetcher
    :: Tracer IO NetworkLayerLog
    -> W.GenesisParameters
    -- ^ Used to convert tips for logging
    -> TQueue IO (LocalStateQueryCmd (CardanoBlock StandardCrypto) IO)
    -> IO ( Observer IO W.RewardAccount W.Coin
          , (AnyCardanoEra, Tip (CardanoBlock StandardCrypto)) -> IO ()
            -- Call on tip-change to refresh
          )
newRewardBalanceFetcher tr gp queryRewardQ =
    newObserver (contramap MsgObserverLog tr) fetch
  where
    fetch
        :: (AnyCardanoEra, Tip (CardanoBlock StandardCrypto))
        -> Set W.RewardAccount
        -> IO (Maybe (Map W.RewardAccount W.Coin))
    fetch (era, tip) accounts = do
        liftIO $ traceWith tr $
            MsgGetRewardAccountBalance (fromTip' gp tip) accounts
        case era of
            AnyCardanoEra ByronEra -> do
                return (Just defaultValue)
            AnyCardanoEra ShelleyEra -> do
                let creds = Set.map toStakeCredential accounts
                let q = QueryIfCurrentShelley (Shelley.GetFilteredDelegationsAndRewardAccounts creds)
                let cmd = CmdQueryLocalState (getTipPoint tip) q
                res <- liftIO . timeQryAndLog loggerName tr $ queryRewardQ `send` cmd
                handleQueryResult defaultValue res
            AnyCardanoEra AllegraEra -> do
                let creds = Set.map toStakeCredential accounts
                let q = QueryIfCurrentAllegra (Shelley.GetFilteredDelegationsAndRewardAccounts creds)
                let cmd = CmdQueryLocalState (getTipPoint tip) q
                res <- liftIO . timeQryAndLog loggerName tr $ queryRewardQ `send` cmd
                handleQueryResult defaultValue res
            AnyCardanoEra MaryEra -> do
                let msg = MsgLocalStateQueryError DelegationRewardsClient "MaryEra Not implemented"
                liftIO $ traceWith tr msg
                return Nothing
      where
        defaultValue :: Map W.RewardAccount W.Coin
        defaultValue = Map.fromList . map (, minBound) $ Set.toList accounts

        loggerName :: String
        loggerName = "getAccountBalance"

    handleQueryResult
        :: Map W.RewardAccount W.Coin
        -> Either AcquireFailure
            (Either
                ( MismatchEraInfo (CardanoEras StandardCrypto))
                ( Map (SL.Credential 'SL.Staking crypto)
                     (SL.KeyHash 'SL.StakePool StandardCrypto)
                , SL.RewardAccounts crypto
                )
            )
        -> IO (Maybe (Map W.RewardAccount W.Coin))
    handleQueryResult defaultValue = \case
        Right (Right (deleg, rewardAccounts)) -> do
            liftIO $ traceWith tr $ MsgAccountDelegationAndRewards deleg rewardAccounts
            let convert = Map.mapKeys fromStakeCredential . Map.map fromShelleyCoin
            return $ Just $ convert rewardAccounts

        Right (Left mismatch) -> do
            liftIO $ traceWith tr $ MsgLocalStateQueryEraMismatch mismatch
            return (Just defaultValue)

        Left acqFail -> do
            -- NOTE: this could possibly happen in rare circumstances when
            -- the chain is switched and the local state query is made
            -- before the node tip variable is updated.
            let msg = MsgLocalStateQueryError DelegationRewardsClient $ show acqFail
            liftIO $ traceWith tr msg
            return Nothing

data ObserverLog key value
    = MsgWillFetch (Set key)
    | MsgDidFetch (Map key value)
    | MsgAddedObserver key
    | MsgRemovedObserver key
    deriving (Eq, Show)

instance (Ord key, Buildable key, Buildable value)
    => ToText (ObserverLog key value) where
    toText (MsgWillFetch keys) = mconcat
        [ "Will fetch values for keys "
        , fmt $ listF keys
        ]
    toText (MsgDidFetch m) = mconcat
        [ "Did fetch values "
        , fmt $ mapF m
        ]
    toText (MsgAddedObserver key) = mconcat
        [ "Started observing values for key "
        , pretty key
        ]
    toText (MsgRemovedObserver key) = mconcat
        [ "Stopped observing values for key "
        , pretty key
        ]

-- | Given a way to fetch values for a set of keys, create:
-- 1. An @Observer@ for consuming values
-- 2. A refresh action
--
-- The @env@ parameter can be used to pass in information needed for refreshing,
-- like the current tip when fetching rewards.
--
-- If the given @fetch@ function returns @Nothing@ the the cache will not be
-- updated.
--
-- If it returns @Just values@, the cache will be set to @values@.
newObserver
    :: forall m key value env. (MonadSTM m, Ord key)
    => Tracer m (ObserverLog key value)
    -> (env -> Set key -> m (Maybe (Map key value)))
    -> m (Observer m key value, env -> m ())
newObserver tr fetch = do
    cacheVar <- atomically $ newTVar Map.empty
    toBeObservedVar <- atomically $ newTVar Set.empty
    return (observer cacheVar toBeObservedVar, refresh cacheVar toBeObservedVar)
  where
    observer
        :: TVar m (Map key value)
        -> TVar m (Set key)
        -> Observer m key value
    observer cacheVar observedKeysVar =
        Observer
            { startObserving = \k -> do
                wasAdded <- atomically $ do
                    notAlreadyThere <- Set.notMember k <$> readTVar observedKeysVar
                    modifyTVar' observedKeysVar (Set.insert k)
                    return notAlreadyThere
                when wasAdded $ traceWith tr $ MsgAddedObserver k
            , stopObserving = \k -> do
                atomically $ do
                    modifyTVar' observedKeysVar (Set.delete k)
                    modifyTVar' cacheVar (Map.delete k)
                traceWith tr $ MsgRemovedObserver k
            , query = \k -> do
                m <- atomically (readTVar cacheVar)
                return $ Map.lookup k m
            }

    refresh
        :: TVar m (Map key value)
        -> TVar m (Set key)
        -> env
        -> m ()
    refresh cacheVar observedKeysVar env = do
        keys <- atomically $ readTVar observedKeysVar
        traceWith tr $ MsgWillFetch keys
        mvalues <- fetch env keys

        case mvalues of
            Nothing -> pure ()
            Just values -> do
                traceWith tr $ MsgDidFetch values
                atomically $ writeTVar cacheVar values

-- | Return a function to run an action only if its single parameter has changed
-- since the previous time it was called.
debounce :: (Eq a, MonadSTM m) => (a -> m ()) -> m (a -> m ())
debounce action = do
    mvar <- newTMVarIO Nothing
    pure $ \cur -> do
        prev <- atomically $ takeTMVar mvar
        unless (Just cur == prev) $ action cur
        atomically $ putTMVar mvar (Just cur)

-- | Convenience function to measure the time of a LSQ query,
-- and trace the result.
--
-- Such that we can get logs like:
-- >>> Query getAccountBalance took 51.664463s
--
-- Failures that stop the >>= continuation will cause the corresponding
-- measuremens /not/ to be logged.
timeQryAndLog
    :: MonadIO m
    => String
    -- ^ Label to identify the query
    -> Tracer m NetworkLayerLog
    -- ^ Tracer to which the measurement will be logged
    -> m a
    -- ^ The action that submits the query.
    -> m a
timeQryAndLog label tr act = do
    t0 <- liftIO getCurrentTime
    a <- act
    t1 <- liftIO getCurrentTime
    let diff = t1 `diffUTCTime` t0
    traceWith tr $ MsgQueryTime label diff
    return a

-- | A protocol client that will never leave the initial state.
doNothingProtocol
    :: MonadTimer m => RunMiniProtocol 'InitiatorMode ByteString m a Void
doNothingProtocol =
    InitiatorProtocolOnly $ MuxPeerRaw $
    const $ forever $ threadDelay 1e6

-- Connect a client to a network, see `mkWalletClient` to construct a network
-- client interface.
--
-- >>> connectClient (mkWalletClient tr gp queue) mainnetVersionData addrInfo
connectClient
    :: Tracer IO NetworkLayerLog
    -> RetryHandlers
    -> NetworkClient IO
    -> NodeToClientVersionData
    -> FilePath
    -> IO ()
connectClient tr handlers client vData addr = withIOManager $ \iocp -> do
    let versions = simpleSingletonVersions nodeToClientVersion vData client
    let tracers = NetworkConnectTracers
            { nctMuxTracer = nullTracer
            , nctHandshakeTracer = contramap MsgHandshakeTracer tr
            }
    let socket = localSnocket iocp addr
    recovering policy (coerceHandlers handlers) $ \status -> do
        traceWith tr $ MsgCouldntConnect (rsIterNumber status)
        connectTo socket tracers versions addr
  where
    -- .25s -> .25s -> .5s → .75s → 1.25s → 2s
    policy :: RetryPolicyM IO
    policy = fibonacciBackoff 250_000 & capDelay 2_000_000

-- | Shorthand for the list of exception handlers used with 'recovering'.
type RetryHandlers = [RetryStatus -> Handler IO Bool]

coerceHandlers :: [RetryStatus -> Handler IO Bool] -> [RetryStatus -> E.Handler IO Bool]
coerceHandlers = map (\f s -> coerceHandler (f s))

coerceHandler :: Handler IO Bool -> E.Handler IO Bool
coerceHandler (Handler h) = E.Handler h

-- | Handlers that are retrying on every connection lost.
retryOnConnectionLost :: Tracer IO NetworkLayerLog -> RetryHandlers
retryOnConnectionLost tr =
    [ const $ Handler $ handleIOException tr' True
    , const $ Handler $ handleMuxError tr' True
    ]
  where
    tr' = contramap MsgConnectionLost tr

-- | Handlers that are failing if the connection is lost
failOnConnectionLost :: Tracer IO NetworkLayerLog -> RetryHandlers
failOnConnectionLost tr =
    [ const $ Handler $ handleIOException tr' False
    , const $ Handler $ handleMuxError tr' False
    ]
  where
    tr' = contramap MsgConnectionLost tr

-- When the node's connection vanished, we may also want to handle things in a
-- slightly different way depending on whether we are a waller worker or just
-- the node's tip thread.
handleIOException
    :: Tracer IO (Maybe IOException)
    -> Bool -- ^ 'True' = retry on 'ResourceVanishedError'
    -> IOException
    -> IO Bool
handleIOException tr onResourceVanished e
    -- There's a race-condition when starting the wallet and the node at the
    -- same time: the socket might not be there yet when we try to open it.
    -- In such case, we simply retry a bit later and hope it's there.
    | isDoesNotExistError e =
        pure True

    -- If the nonblocking UNIX domain socket connection cannot be completed
    -- immediately (i.e. connect() returns EAGAIN), try again. This happens
    -- because the node's listen queue is quite short.
    | isTryAgainError e =
        pure True

    | isResourceVanishedError e = do
        traceWith tr $ Just e
        pure onResourceVanished

    | otherwise =
        pure False
  where
    isResourceVanishedError = isInfixOf "resource vanished" . show
    isTryAgainError = isInfixOf "resource exhausted" . show

handleMuxError
    :: Tracer IO (Maybe IOException)
    -> Bool -- ^ 'True' = retry on 'ResourceVanishedError'
    -> MuxError
    -> IO Bool
handleMuxError tr onResourceVanished = pure . errorType >=> \case
    MuxUnknownMiniProtocol -> pure False
    MuxDecodeError -> pure False
    MuxIngressQueueOverRun -> pure False
    MuxInitiatorOnly -> pure False
    MuxSDUReadTimeout -> pure False
    MuxSDUWriteTimeout -> pure False
    MuxShutdown _ -> pure False -- fixme: #2212 consider cases
    MuxIOException e ->
        handleIOException tr onResourceVanished e
    MuxBearerClosed -> do
        traceWith tr Nothing
        pure onResourceVanished
    MuxCleanShutdown -> pure False

{-------------------------------------------------------------------------------
                                    Logging
-------------------------------------------------------------------------------}

data NetworkLayerLog where
    MsgCouldntConnect :: Int -> NetworkLayerLog
    MsgConnectionLost :: Maybe IOException -> NetworkLayerLog
    MsgTxSubmission
        :: (TraceSendRecv
            (LocalTxSubmission (GenTx (CardanoBlock StandardCrypto)) (CardanoApplyTxErr StandardCrypto)))
        -> NetworkLayerLog
    MsgLocalStateQuery
        :: QueryClientName
        -> (TraceSendRecv
            (LocalStateQuery (CardanoBlock StandardCrypto) (Point (CardanoBlock StandardCrypto)) (Query (CardanoBlock StandardCrypto))))
        -> NetworkLayerLog
    MsgHandshakeTracer ::
      (WithMuxBearer (ConnectionId LocalAddress) HandshakeTrace) -> NetworkLayerLog
    MsgFindIntersection :: [W.BlockHeader] -> NetworkLayerLog
    MsgIntersectionFound :: (W.Hash "BlockHeader") -> NetworkLayerLog
    MsgFindIntersectionTimeout :: NetworkLayerLog
    MsgPostTx :: W.SealedTx -> NetworkLayerLog
    MsgNodeTip :: W.BlockHeader -> NetworkLayerLog
    MsgProtocolParameters :: W.ProtocolParameters -> NetworkLayerLog
    MsgLocalStateQueryError :: QueryClientName -> String -> NetworkLayerLog
    MsgLocalStateQueryEraMismatch :: MismatchEraInfo (CardanoEras StandardCrypto) -> NetworkLayerLog
    MsgGetRewardAccountBalance
        :: W.BlockHeader
        -> Set W.RewardAccount
        -> NetworkLayerLog
    MsgAccountDelegationAndRewards
        :: forall era. (Map (SL.Credential 'SL.Staking era) (SL.KeyHash 'SL.StakePool StandardCrypto))
        -> SL.RewardAccounts era
        -> NetworkLayerLog
    MsgDestroyCursor :: ThreadId -> NetworkLayerLog
    MsgWillQueryRewardsForStake :: W.Coin -> NetworkLayerLog
    MsgFetchStakePoolsData :: Maybe W.StakePoolsSummary -> NetworkLayerLog
    MsgFetchStakePoolsDataSummary :: Int -> Int -> NetworkLayerLog
      -- ^ Number of pools in stake distribution, and rewards map,
      -- respectively.
    MsgWatcherUpdate :: W.BlockHeader -> BracketLog -> NetworkLayerLog
    MsgChainSyncCmd :: (ChainSyncLog Text Text) -> NetworkLayerLog
    MsgInterpreter :: CardanoInterpreter StandardCrypto -> NetworkLayerLog
    -- TODO: Combine ^^ and vv
    MsgInterpreterLog :: TimeInterpreterLog -> NetworkLayerLog
    MsgQueryTime :: String -> NominalDiffTime -> NetworkLayerLog
    MsgObserverLog
        :: ObserverLog W.RewardAccount W.Coin
        -> NetworkLayerLog

data QueryClientName
    = TipSyncClient
    | DelegationRewardsClient
    deriving (Show, Eq)

type HandshakeTrace = TraceSendRecv (Handshake NodeToClientVersion CBOR.Term)

instance ToText NetworkLayerLog where
    toText = \case
        MsgCouldntConnect n -> T.unwords
            [ "Couldn't connect to node (x" <> toText (n + 1) <> ")."
            , "Retrying in a bit..."
            ]
        MsgConnectionLost Nothing  ->
            "Connection lost with the node."
        MsgConnectionLost (Just e) -> T.unwords
            [ toText (MsgConnectionLost Nothing)
            , T.pack (show e)
            ]
        MsgTxSubmission msg ->
            T.pack (show msg)
        MsgHandshakeTracer (WithMuxBearer conn h) ->
            pretty conn <> " " <> T.pack (show h)
        MsgFindIntersectionTimeout ->
            "Couldn't find an intersection in a timely manner. Retrying..."
        MsgFindIntersection points -> T.unwords
            [ "Looking for an intersection with the node's local chain with:"
            , T.intercalate ", " (pretty <$> points)
            ]
        MsgIntersectionFound point -> T.unwords
            [ "Intersection found:", pretty point ]
        MsgPostTx (W.SealedTx bytes) -> T.unwords
            [ "Posting transaction, serialized as:"
            , T.decodeUtf8 $ convertToBase Base16 bytes
            ]
        MsgLocalStateQuery client msg ->
            T.pack (show client <> " " <> show msg)
        MsgNodeTip bh -> T.unwords
            [ "Network node tip is"
            , pretty bh
            ]
        MsgProtocolParameters params -> T.unlines
            [ "Protocol parameters for tip are:"
            , pretty params
            ]
        MsgLocalStateQueryError client e -> T.pack $ mconcat
            [ "Error when querying local state parameters for "
            , show client
            , ": "
            , e
            ]
        MsgLocalStateQueryEraMismatch mismatch ->
            "Local state query for the wrong era - this is fine. " <>
            T.pack (show mismatch)
        MsgGetRewardAccountBalance tip accts -> T.unwords
            [ "Querying the reward account balance for"
            , fmt $ listF accts
            , "at"
            , pretty tip
            ]
        MsgAccountDelegationAndRewards delegations rewards -> T.unlines
            [ "  delegations = " <> T.pack (show delegations)
            , "  rewards = " <> T.pack (show rewards)
            ]
        MsgDestroyCursor threadId -> T.unwords
            [ "Destroying cursor connection at"
            , T.pack (show threadId)
            ]
        MsgWillQueryRewardsForStake c ->
            "Will query non-myopic rewards using the stake " <> pretty c
        MsgFetchStakePoolsData d ->
            "Fetched pool data from node tip using LSQ: " <> pretty d
        MsgFetchStakePoolsDataSummary inStake inRewards -> mconcat
            [ "Fetched pool data from node tip using LSQ. Got "
            , T.pack (show inStake)
            , " pools in the stake distribution, and "
            , T.pack (show inRewards)
            , " pools in the non-myopic member reward map."
            ]
        MsgWatcherUpdate tip b ->
            "Update watcher with tip: " <> pretty tip <>
            ". Callback " <> toText b <> "."
        MsgQueryTime qry diffTime ->
            "Query " <> T.pack qry <> " took " <> T.pack (show diffTime)
        MsgChainSyncCmd a -> toText a
        MsgInterpreter interpreter ->
            "Updated the history interpreter: " <> T.pack (show interpreter)
        MsgInterpreterLog msg -> toText msg
        MsgObserverLog msg -> toText msg

instance HasPrivacyAnnotation NetworkLayerLog
instance HasSeverityAnnotation NetworkLayerLog where
    getSeverityAnnotation = \case
        MsgCouldntConnect 0                -> Debug
        MsgCouldntConnect 1                -> Notice
        MsgCouldntConnect{}                -> Warning
        MsgConnectionLost{}                -> Warning
        MsgTxSubmission{}                  -> Info
        MsgHandshakeTracer{}               -> Info
        MsgFindIntersectionTimeout         -> Warning
        MsgFindIntersection{}              -> Info
        MsgIntersectionFound{}             -> Info
        MsgPostTx{}                        -> Debug
        MsgLocalStateQuery{}               -> Debug
        MsgNodeTip{}                       -> Debug
        MsgProtocolParameters{}            -> Info
        MsgLocalStateQueryError{}          -> Error
        MsgLocalStateQueryEraMismatch{}    -> Debug
        MsgGetRewardAccountBalance{}       -> Info
        MsgAccountDelegationAndRewards{}   -> Info
        MsgDestroyCursor{}                 -> Notice
        MsgWillQueryRewardsForStake{}      -> Info
        MsgFetchStakePoolsData{}           -> Debug
        MsgFetchStakePoolsDataSummary{}    -> Info
        MsgWatcherUpdate{}                 -> Debug
        MsgChainSyncCmd cmd                -> getSeverityAnnotation cmd
        MsgInterpreter{}                   -> Debug
        MsgQueryTime{}                     -> Info
        MsgInterpreterLog msg              -> getSeverityAnnotation msg
        MsgObserverLog{}                   -> Debug
