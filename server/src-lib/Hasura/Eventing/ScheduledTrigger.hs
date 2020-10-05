{-|
= Scheduled Triggers

This module implements the functionality of invoking webhooks during specified
time events aka scheduled events. The scheduled events are the events generated
by the graphql-engine using the cron triggers or/and a scheduled event can
be created by the user at a specified time with the payload, webhook, headers
and the retry configuration. Scheduled events are modeled using rows in Postgres
with a @timestamp@ column.

This module implements scheduling and delivery of scheduled
events:

1. Scheduling a cron event involves creating new cron events. New
cron events are created based on the cron schedule and the number of
scheduled events that are already present in the scheduled events buffer.
The graphql-engine computes the new scheduled events and writes them to
the database.(Generator)

2. Delivering a scheduled event involves reading undelivered scheduled events
from the database and delivering them to the webhook server. (Processor)

The rationale behind separating the event scheduling and event delivery
mechanism into two different threads is that the scheduling and delivering of
the scheduled events are not directly dependent on each other. The generator
will almost always try to create scheduled events which are supposed to be
delivered in the future (timestamp > current_timestamp) and the processor
will fetch scheduled events of the past (timestamp < current_timestamp). So,
the set of the scheduled events generated by the generator and the processor
will never be the same. The point here is that they're not correlated to each
other. They can be split into different threads for a better performance.

== Implementation

During the startup, two threads are started:

1. Generator: Fetches the list of scheduled triggers from cache and generates
   the scheduled events.

    - Additional events will be generated only if there are fewer than 100
      scheduled events.

    - The upcoming events timestamp will be generated using:

        - cron schedule of the scheduled trigger

        - max timestamp of the scheduled events that already exist or
          current_timestamp(when no scheduled events exist)

        - The timestamp of the scheduled events is stored with timezone because
          `SELECT NOW()` returns timestamp with timezone, so it's good to
          compare two things of the same type.

    This effectively corresponds to doing an INSERT with values containing
    specific timestamp.

2. Processor: Fetches the undelivered cron events and the scheduled events
   from the database and which have timestamp lesser than the
   current timestamp and then process them.
-}
module Hasura.Eventing.ScheduledTrigger
  ( runCronEventsGenerator
  , processScheduledTriggers

  , CronEventSeed(..)
  , generateScheduleTimes
  , insertCronEvents
  , initLockedEventsCtx
  , LockedEventsCtx(..)
  , unlockCronEvents
  , unlockOneOffScheduledEvents
  , unlockAllLockedScheduledEvents
  ) where

import           Control.Arrow.Extended      (dup)
import           Control.Concurrent.Extended (sleep)
import           Control.Concurrent.STM.TVar
import           Data.Has
import           Data.Int                    (Int64)
import           Data.List                   (unfoldr)
import           Data.Time.Clock
import           Hasura.Eventing.Common
import           Hasura.Eventing.HTTP
import           Hasura.HTTP
import           Hasura.Prelude
import           Hasura.RQL.DDL.EventTrigger (getHeaderInfosFromConf)
import           Hasura.RQL.DDL.Headers
import           Hasura.RQL.Types
import           Hasura.Server.Version       (HasVersion)
import           Hasura.SQL.DML
import           Hasura.SQL.Types
import           System.Cron

import qualified Data.Aeson                  as J
import qualified Data.Aeson.Casing           as J
import qualified Data.Aeson.TH               as J
import qualified Data.ByteString.Lazy        as BL
import qualified Data.Environment            as Env
import qualified Data.HashMap.Strict         as Map
import qualified Data.Set                    as Set
import qualified Data.TByteString            as TBS
import qualified Data.Text                   as T
import qualified Database.PG.Query           as Q
import qualified Database.PG.Query.PTI       as PTI
import qualified Hasura.Logging              as L
import qualified Hasura.Tracing              as Tracing
import qualified Network.HTTP.Client         as HTTP
import qualified PostgreSQL.Binary.Decoding  as PD
import qualified PostgreSQL.Binary.Encoding  as PE
import qualified Text.Builder                as TB (run)


newtype ScheduledTriggerInternalErr
  = ScheduledTriggerInternalErr QErr
  deriving (Show, Eq)

instance L.ToEngineLog ScheduledTriggerInternalErr L.Hasura where
  toEngineLog (ScheduledTriggerInternalErr qerr) =
    (L.LevelError, L.scheduledTriggerLogType, J.toJSON qerr)

cronEventsTable :: QualifiedTable
cronEventsTable =
  QualifiedObject
    hdbCatalogSchema
    (TableName $ T.pack "hdb_cron_events")

data ScheduledEventStatus
  = SESScheduled
  | SESLocked
  | SESDelivered
  | SESError
  | SESDead
  deriving (Show, Eq)

scheduledEventStatusToText :: ScheduledEventStatus -> Text
scheduledEventStatusToText SESScheduled = "scheduled"
scheduledEventStatusToText SESLocked    = "locked"
scheduledEventStatusToText SESDelivered = "delivered"
scheduledEventStatusToText SESError     = "error"
scheduledEventStatusToText SESDead      = "dead"

instance Q.ToPrepArg ScheduledEventStatus where
  toPrepVal = Q.toPrepVal . scheduledEventStatusToText

instance Q.FromCol ScheduledEventStatus where
  fromCol bs = flip Q.fromColHelper bs $ PD.enum $ \case
    "scheduled" -> Just SESScheduled
    "locked"    -> Just SESLocked
    "delivered" -> Just SESDelivered
    "error"     -> Just SESError
    "dead"      -> Just SESDead
    _           -> Nothing

instance J.ToJSON ScheduledEventStatus where
  toJSON = J.String . scheduledEventStatusToText

type ScheduledEventId = Text

data CronTriggerStats
  = CronTriggerStats
  { ctsName                :: !TriggerName
  , ctsUpcomingEventsCount :: !Int
  , ctsMaxScheduledTime    :: !UTCTime
  } deriving (Show, Eq)

data CronEventSeed
  = CronEventSeed
  { cesName          :: !TriggerName
  , cesScheduledTime :: !UTCTime
  } deriving (Show, Eq)

data CronEventPartial
  = CronEventPartial
  { cepId            :: !CronEventId
  , cepName          :: !TriggerName
  , cepScheduledTime :: !UTCTime
  , cepTries         :: !Int
  , cepCreatedAt     :: !UTCTime
  -- ^ cepCreatedAt is the time at which the cron event generator
  -- created the cron event
  } deriving (Show, Eq)

data ScheduledEventFull
  = ScheduledEventFull
  { sefId            :: !ScheduledEventId
  , sefName          :: !(Maybe TriggerName)
  -- ^ sefName is the name of the cron trigger.
  -- A one-off scheduled event is not associated with a name, so in that
  -- case, 'sefName' will be @Nothing@
  , sefScheduledTime :: !UTCTime
  , sefTries         :: !Int
  , sefWebhook       :: !Text
  , sefPayload       :: !J.Value
  , sefRetryConf     :: !STRetryConf
  , sefHeaders       :: ![EventHeaderInfo]
  , sefComment       :: !(Maybe Text)
  , sefCreatedAt     :: !UTCTime
  } deriving (Show, Eq)
$(J.deriveToJSON (J.aesonDrop 3 J.snakeCase) {J.omitNothingFields = True} ''ScheduledEventFull)

data OneOffScheduledEvent
  = OneOffScheduledEvent
  { ooseId            :: !OneOffScheduledEventId
  , ooseScheduledTime :: !UTCTime
  , ooseTries         :: !Int
  , ooseWebhook       :: !InputWebhook
  , oosePayload       :: !(Maybe J.Value)
  , ooseRetryConf     :: !STRetryConf
  , ooseHeaderConf    :: ![HeaderConf]
  , ooseComment       :: !(Maybe Text)
  , ooseCreatedAt     :: !UTCTime
  } deriving (Show, Eq)
$(J.deriveToJSON (J.aesonDrop 4 J.snakeCase) {J.omitNothingFields = True} ''OneOffScheduledEvent)

-- | The 'ScheduledEventType' data type is needed to differentiate
--   between a 'CronScheduledEvent' and 'OneOffScheduledEvent' scheduled
--   event because they both have different configurations
--   and they live in different tables.
data ScheduledEventType =
    Cron
  -- ^ A Cron scheduled event has a template defined which will
  -- contain the webhook, header configuration, retry
  -- configuration and a payload. Every cron event created
  -- uses the above mentioned configurations defined in the template.
  -- The configuration defined with the cron trigger is cached
  -- and hence it's not fetched along the cron scheduled events.
  | OneOff
  -- ^ A One-off scheduled event doesn't have any template defined
  -- so all the configuration is fetched along the scheduled events.
    deriving (Eq, Show)

data ScheduledEventWebhookPayload
  = ScheduledEventWebhookPayload
  { sewpId            :: !Text
  , sewpName          :: !(Maybe TriggerName)
  , sewpScheduledTime :: !UTCTime
  , sewpPayload       :: !J.Value
  , sewpComment       :: !(Maybe Text)
  , sewpCreatedAt     :: !(Maybe UTCTime)
  -- ^ sewpCreatedAt is the time at which the event was created,
  -- In case of one-off scheduled events, it's the time at which
  -- the user created the event and in case of cron triggers, the
  -- graphql-engine generator, generates the cron events, the
  -- `created_at` is just an implementation detail, so we
  -- don't send it
  } deriving (Show, Eq)

$(J.deriveToJSON (J.aesonDrop 4 J.snakeCase) {J.omitNothingFields = True} ''ScheduledEventWebhookPayload)

-- | runCronEventsGenerator makes sure that all the cron triggers
--   have an adequate buffer of cron events.
runCronEventsGenerator ::
     L.Logger L.Hasura
  -> Q.PGPool
  -> IO SchemaCache
  -> IO void
runCronEventsGenerator logger pgpool getSC = do
  forever $ do
    sc <- getSC
    -- get cron triggers from cache
    let cronTriggersCache = scCronTriggers sc

    -- get cron trigger stats from db
    runExceptT
      (Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadOnly) getDeprivedCronTriggerStats) >>= \case
      Left err -> L.unLogger logger $
        ScheduledTriggerInternalErr $ err500 Unexpected (T.pack $ show err)
      Right deprivedCronTriggerStats -> do
        -- join stats with cron triggers and produce @[(CronTriggerInfo, CronTriggerStats)]@
        cronTriggersForHydrationWithStats <-
          catMaybes <$>
          mapM (withCronTrigger cronTriggersCache) deprivedCronTriggerStats
        -- insert cron events for cron triggers that need hydration
        runExceptT
          (Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadWrite) $
          insertCronEventsFor cronTriggersForHydrationWithStats) >>= \case
          Right _ -> pure ()
          Left err ->
            L.unLogger logger $ ScheduledTriggerInternalErr $ err500 Unexpected (T.pack $ show err)
    sleep (minutes 1)
    where
      getDeprivedCronTriggerStats = liftTx $ do
        map uncurryStats <$>
          Q.listQE defaultTxErrorHandler
          [Q.sql|
           SELECT name, upcoming_events_count, max_scheduled_time
            FROM hdb_catalog.hdb_cron_events_stats
            WHERE upcoming_events_count < 100
           |] () True

      uncurryStats (n, count, maxTs) = CronTriggerStats n count maxTs

      withCronTrigger cronTriggerCache cronTriggerStat = do
        case Map.lookup (ctsName cronTriggerStat) cronTriggerCache of
          Nothing -> do
            L.unLogger logger $
              ScheduledTriggerInternalErr $
                err500 Unexpected $
                "could not find scheduled trigger in the schema cache"
            pure Nothing
          Just cronTrigger -> pure $
            Just (cronTrigger, cronTriggerStat)

insertCronEventsFor :: [(CronTriggerInfo, CronTriggerStats)] -> Q.TxE QErr ()
insertCronEventsFor cronTriggersWithStats = do
  let scheduledEvents = flip concatMap cronTriggersWithStats $ \(cti, stats) ->
        generateCronEventsFrom (ctsMaxScheduledTime stats) cti
  case scheduledEvents of
    []     -> pure ()
    events -> do
      let insertCronEventsSql = TB.run $ toSQL
            SQLInsert
              { siTable    = cronEventsTable
              , siCols     = map unsafePGCol ["trigger_name", "scheduled_time"]
              , siValues   = ValuesExp $ map (toTupleExp . toArr) events
              , siConflict = Just $ DoNothing Nothing
              , siRet      = Nothing
              }
      Q.unitQE defaultTxErrorHandler (Q.fromText insertCronEventsSql) () False
  where
    toArr (CronEventSeed n t) = [(triggerNameToTxt n), (formatTime' t)]
    toTupleExp = TupleExp . map SELit

insertCronEvents :: [CronEventSeed] -> Q.TxE QErr ()
insertCronEvents events = do
  let insertCronEventsSql = TB.run $ toSQL
        SQLInsert
          { siTable    = cronEventsTable
          , siCols     = map unsafePGCol ["trigger_name", "scheduled_time"]
          , siValues   = ValuesExp $ map (toTupleExp . toArr) events
          , siConflict = Just $ DoNothing Nothing
          , siRet      = Nothing
          }
  Q.unitQE defaultTxErrorHandler (Q.fromText insertCronEventsSql) () False
  where
    toArr (CronEventSeed n t) = [(triggerNameToTxt n), (formatTime' t)]
    toTupleExp = TupleExp . map SELit

generateCronEventsFrom :: UTCTime -> CronTriggerInfo-> [CronEventSeed]
generateCronEventsFrom startTime CronTriggerInfo{..} =
  map (CronEventSeed ctiName) $
      generateScheduleTimes startTime 100 ctiSchedule -- generate next 100 events

-- | Generates next @n events starting @from according to 'CronSchedule'
generateScheduleTimes :: UTCTime -> Int -> CronSchedule -> [UTCTime]
generateScheduleTimes from n cron = take n $ go from
  where
    go = unfoldr (fmap dup . nextMatch cron)

processCronEvents
  :: (HasVersion, MonadIO m, Tracing.HasReporter m)
  => L.Logger L.Hasura
  -> LogEnvHeaders
  -> HTTP.Manager
  -> Q.PGPool
  -> IO SchemaCache
  -> TVar (Set.Set CronEventId)
  -> m ()
processCronEvents logger logEnv httpMgr pgpool getSC lockedCronEvents = do
  cronTriggersInfo <- scCronTriggers <$> liftIO getSC
  cronScheduledEvents <-
    liftIO . runExceptT $
      Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadWrite) getPartialCronEvents
  case cronScheduledEvents of
    Right partialEvents -> do
      -- save the locked cron events that have been fetched from the
      -- database, the events stored here will be unlocked in case a
      -- graceful shutdown is initiated in midst of processing these events
      saveLockedEvents (map cepId partialEvents) lockedCronEvents
      -- The `createdAt` of a cron event is the `created_at` of the cron trigger
      for_ partialEvents $ \(CronEventPartial id' name st tries createdAt)-> do
        case Map.lookup name cronTriggersInfo of
          Nothing ->  logInternalError $
            err500 Unexpected "could not find cron trigger in cache"
          Just CronTriggerInfo{..} -> do
            let webhook = unResolvedWebhook ctiWebhookInfo
                payload' = fromMaybe J.Null ctiPayload
                scheduledEvent =
                    ScheduledEventFull id'
                                       (Just name)
                                       st
                                       tries
                                       webhook
                                       payload'
                                       ctiRetryConf
                                       ctiHeaders
                                       ctiComment
                                       createdAt
            finally <- runExceptT $
              runReaderT (processScheduledEvent logEnv pgpool scheduledEvent Cron) (logger, httpMgr)
            removeEventFromLockedEvents id' lockedCronEvents
            either logInternalError pure finally
    Left err -> logInternalError err
  where
    logInternalError err = liftIO . L.unLogger logger $ ScheduledTriggerInternalErr err

processOneOffScheduledEvents
  :: (HasVersion, MonadIO m, Tracing.HasReporter m)
  => Env.Environment
  -> L.Logger L.Hasura
  -> LogEnvHeaders
  -> HTTP.Manager
  -> Q.PGPool
  -> TVar (Set.Set OneOffScheduledEventId)
  -> m ()
processOneOffScheduledEvents env logger logEnv httpMgr pgpool lockedOneOffScheduledEvents = do
  oneOffScheduledEvents <-
    liftIO . runExceptT $
      Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadWrite) getOneOffScheduledEvents
  case oneOffScheduledEvents of
    Right oneOffScheduledEvents' -> do
      -- save the locked one-off events that have been fetched from the
      -- database, the events stored here will be unlocked in case a
      -- graceful shutdown is initiated in midst of processing these events
      saveLockedEvents (map ooseId oneOffScheduledEvents') lockedOneOffScheduledEvents
      for_ oneOffScheduledEvents' $
             \(OneOffScheduledEvent id'
                                    scheduledTime
                                    tries
                                    webhookConf
                                    payload
                                    retryConf
                                    headerConf
                                    comment
                                    createdAt)
        -> do
        webhookInfo <- liftIO . runExceptT $ resolveWebhook env webhookConf
        headerInfo <- liftIO . runExceptT $ getHeaderInfosFromConf env headerConf

        case webhookInfo of
          Right webhookInfo' -> do
            case headerInfo of
              Right headerInfo' -> do
                let webhook = unResolvedWebhook webhookInfo'
                    payload' = fromMaybe J.Null payload
                    scheduledEvent = ScheduledEventFull id'
                                                        Nothing
                                                        scheduledTime
                                                        tries
                                                        webhook
                                                        payload'
                                                        retryConf
                                                        headerInfo'
                                                        comment
                                                        createdAt
                finally <- runExceptT $
                  runReaderT (processScheduledEvent logEnv pgpool scheduledEvent OneOff) $
                    (logger, httpMgr)
                removeEventFromLockedEvents id' lockedOneOffScheduledEvents
                either logInternalError pure finally

              Left headerInfoErr -> logInternalError headerInfoErr

          Left webhookInfoErr -> logInternalError webhookInfoErr

    Left oneOffScheduledEventsErr -> logInternalError oneOffScheduledEventsErr
  where
    logInternalError err = liftIO . L.unLogger logger $ ScheduledTriggerInternalErr err

processScheduledTriggers
  :: (HasVersion, MonadIO m, Tracing.HasReporter m)
  => Env.Environment
  -> L.Logger L.Hasura
  -> LogEnvHeaders
  -> HTTP.Manager
  -> Q.PGPool
  -> IO SchemaCache
  -> LockedEventsCtx
  -> m void
processScheduledTriggers env logger logEnv httpMgr pgpool getSC LockedEventsCtx {..} =
  forever $ do
    processCronEvents logger logEnv httpMgr pgpool getSC leCronEvents
    processOneOffScheduledEvents env logger logEnv httpMgr pgpool leOneOffEvents
    liftIO $ sleep (minutes 1)

processScheduledEvent ::
  ( MonadReader r m
  , Has HTTP.Manager r
  , Has (L.Logger L.Hasura) r
  , HasVersion
  , MonadIO m
  , MonadError QErr m
  , Tracing.HasReporter m
  )
  => LogEnvHeaders
  -> Q.PGPool
  -> ScheduledEventFull
  -> ScheduledEventType
  -> m ()
processScheduledEvent logEnv pgpool se@ScheduledEventFull {..} type' = Tracing.runTraceT traceNote do
  currentTime <- liftIO getCurrentTime
  if convertDuration (diffUTCTime currentTime sefScheduledTime)
    > unNonNegativeDiffTime (strcToleranceSeconds sefRetryConf)
    then processDead pgpool se type'
    else do
      let timeoutSeconds = round $ unNonNegativeDiffTime
                             $ strcTimeoutSeconds sefRetryConf
          httpTimeout = HTTP.responseTimeoutMicro (timeoutSeconds * 1000000)
          headers = addDefaultHeaders $ map encodeHeader sefHeaders
          extraLogCtx = ExtraLogContext (Just currentTime) sefId
          -- include `created_at` in the payload, only in one-off events
          createdAt = bool Nothing (Just sefCreatedAt) $ type' == OneOff
          webhookReqPayload =
            ScheduledEventWebhookPayload
              sefId sefName sefScheduledTime sefPayload sefComment createdAt
          webhookReqBodyJson = J.toJSON webhookReqPayload
          webhookReqBody = J.encode webhookReqBodyJson
          requestDetails = RequestDetails $ BL.length webhookReqBody
      res <- runExceptT $ tryWebhook headers httpTimeout webhookReqBody (T.unpack sefWebhook)
      logHTTPForST res extraLogCtx requestDetails
      let decodedHeaders = map (decodeHeader logEnv sefHeaders) headers
      either
        (processError pgpool se decodedHeaders type' webhookReqBodyJson)
        (processSuccess pgpool se decodedHeaders type' webhookReqBodyJson)
        res
  where
    traceNote = "Scheduled trigger" <> foldMap ((": " <>) . unNonEmptyText . unTriggerName) sefName

processError
  :: (MonadIO m, MonadError QErr m)
  => Q.PGPool
  -> ScheduledEventFull
  -> [HeaderConf]
  -> ScheduledEventType
  -> J.Value
  -> HTTPErr a
  -> m ()
processError pgpool se decodedHeaders type' reqJson err = do
  let invocation = case err of
        HClient excp -> do
          let errMsg = TBS.fromLBS $ J.encode $ show excp
          mkInvocation se 1000 decodedHeaders errMsg [] reqJson
        HParse _ detail -> do
          let errMsg = TBS.fromLBS $ J.encode detail
          mkInvocation se 1001 decodedHeaders errMsg [] reqJson
        HStatus errResp -> do
          let respPayload = hrsBody errResp
              respHeaders = hrsHeaders errResp
              respStatus = hrsStatus errResp
          mkInvocation se respStatus decodedHeaders respPayload respHeaders reqJson
        HOther detail -> do
          let errMsg = (TBS.fromLBS $ J.encode detail)
          mkInvocation se 500 decodedHeaders errMsg [] reqJson
  liftExceptTIO $
    Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadWrite) $ do
    insertInvocation invocation type'
    retryOrMarkError se err type'

retryOrMarkError :: ScheduledEventFull -> HTTPErr a -> ScheduledEventType -> Q.TxE QErr ()
retryOrMarkError se@ScheduledEventFull {..} err type' = do
  let mRetryHeader = getRetryAfterHeaderFromHTTPErr err
      mRetryHeaderSeconds = parseRetryHeaderValue =<< mRetryHeader
      triesExhausted = sefTries >= strcNumRetries sefRetryConf
      noRetryHeader = isNothing mRetryHeaderSeconds
  if triesExhausted && noRetryHeader
    then do
      setScheduledEventStatus sefId SESError type'
    else do
      currentTime <- liftIO getCurrentTime
      let delay = fromMaybe (round $ unNonNegativeDiffTime
                             $ strcRetryIntervalSeconds sefRetryConf)
                    $ mRetryHeaderSeconds
          diff = fromIntegral delay
          retryTime = addUTCTime diff currentTime
      setRetry se retryTime type'

{- Note [Scheduled event lifecycle]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Scheduled events move between six different states over the course of their
lifetime, as represented by the following flowchart:
  ┌───────────┐      ┌────────┐      ┌───────────┐
  │ scheduled │─(a)─→│ locked │─(b)─→│ delivered │
  └───────────┘      └────────┘      └───────────┘
          ↑              │           ┌───────┐
          └────(c)───────┼─────(d)──→│ error │
                         │           └───────┘
                         │           ┌──────┐
                         └─────(e)──→│ dead │
                                     └──────┘

When a scheduled event is first created, it starts in the 'scheduled' state,
and it can transition to other states in the following ways:
  a. When graphql-engine fetches a scheduled event from the database to process
     it, it sets its state to 'locked'. This prevents multiple graphql-engine
     instances running on the same database from processing the same
     scheduled event concurrently.
  b. When a scheduled event is processed successfully, it is marked 'delivered'.
  c. If a scheduled event fails to be processed, but it hasn’t yet reached
     its maximum retry limit, its retry counter is incremented and
     it is returned to the 'scheduled' state.
  d. If a scheduled event fails to be processed and *has* reached its
     retry limit, its state is set to 'error'.
  e. If for whatever reason the difference between the current time and the
     scheduled time is greater than the tolerance of the scheduled event, it
     will not be processed and its state will be set to 'dead'.
-}

processSuccess
  :: (MonadIO m, MonadError QErr m)
  => Q.PGPool
  -> ScheduledEventFull
  -> [HeaderConf]
  -> ScheduledEventType
  -> J.Value
  -> HTTPResp a
  -> m ()
processSuccess pgpool se decodedHeaders type' reqBodyJson resp = do
  let respBody = hrsBody resp
      respHeaders = hrsHeaders resp
      respStatus = hrsStatus resp
      invocation = mkInvocation se respStatus decodedHeaders respBody respHeaders reqBodyJson
  liftExceptTIO $
    Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadWrite) $ do
    insertInvocation invocation type'
    setScheduledEventStatus (sefId se) SESDelivered type'

processDead :: (MonadIO m, MonadError QErr m) => Q.PGPool -> ScheduledEventFull -> ScheduledEventType -> m ()
processDead pgpool se type' =
  liftExceptTIO $
  Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadWrite) $
    setScheduledEventStatus (sefId se) SESDead type'

setRetry :: ScheduledEventFull -> UTCTime -> ScheduledEventType ->  Q.TxE QErr ()
setRetry se time type' =
  case type' of
    Cron ->
      Q.unitQE defaultTxErrorHandler [Q.sql|
        UPDATE hdb_catalog.hdb_cron_events
        SET next_retry_at = $1,
        STATUS = 'scheduled'
        WHERE id = $2
        |] (time, sefId se) True
    OneOff ->
      Q.unitQE defaultTxErrorHandler [Q.sql|
        UPDATE hdb_catalog.hdb_scheduled_events
        SET next_retry_at = $1,
        STATUS = 'scheduled'
        WHERE id = $2
        |] (time, sefId se) True

mkInvocation
  :: ScheduledEventFull
  -> Int
  -> [HeaderConf]
  -> TBS.TByteString
  -> [HeaderConf]
  -> J.Value
  -> (Invocation 'ScheduledType)
mkInvocation ScheduledEventFull {sefId} status reqHeaders respBody respHeaders reqBodyJson
  = let resp = if isClientError status
          then mkClientErr respBody
          else mkResp status respBody respHeaders
    in
      Invocation
      sefId
      status
      (mkWebhookReq reqBodyJson reqHeaders invocationVersionST)
      resp

insertInvocation :: (Invocation 'ScheduledType) -> ScheduledEventType ->  Q.TxE QErr ()
insertInvocation invo type' = do
  case type' of
    Cron -> do
      Q.unitQE defaultTxErrorHandler
        [Q.sql|
         INSERT INTO hdb_catalog.hdb_cron_event_invocation_logs
         (event_id, status, request, response)
         VALUES ($1, $2, $3, $4)
        |] ( iEventId invo
             , fromIntegral $ iStatus invo :: Int64
             , Q.AltJ $ J.toJSON $ iRequest invo
             , Q.AltJ $ J.toJSON $ iResponse invo) True
      Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_cron_events
          SET tries = tries + 1
          WHERE id = $1
          |] (Identity $ iEventId invo) True
    OneOff -> do
      Q.unitQE defaultTxErrorHandler
        [Q.sql|
         INSERT INTO hdb_catalog.hdb_scheduled_event_invocation_logs
         (event_id, status, request, response)
         VALUES ($1, $2, $3, $4)
        |] ( iEventId invo
             , fromIntegral $ iStatus invo :: Int64
             , Q.AltJ $ J.toJSON $ iRequest invo
             , Q.AltJ $ J.toJSON $ iResponse invo) True
      Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_scheduled_events
          SET tries = tries + 1
          WHERE id = $1
          |] (Identity $ iEventId invo) True

setScheduledEventStatus :: Text -> ScheduledEventStatus -> ScheduledEventType -> Q.TxE QErr ()
setScheduledEventStatus scheduledEventId status type' =
  case type' of
    Cron -> do
      Q.unitQE defaultTxErrorHandler
       [Q.sql|
        UPDATE hdb_catalog.hdb_cron_events
        SET status = $2
        WHERE id = $1
       |] (scheduledEventId, status) True
    OneOff -> do
      Q.unitQE defaultTxErrorHandler
       [Q.sql|
        UPDATE hdb_catalog.hdb_scheduled_events
        SET status = $2
        WHERE id = $1
       |] (scheduledEventId, status) True

getPartialCronEvents :: Q.TxE QErr [CronEventPartial]
getPartialCronEvents = do
  map uncurryEvent <$> Q.listQE defaultTxErrorHandler [Q.sql|
      UPDATE hdb_catalog.hdb_cron_events
      SET status = 'locked'
      WHERE id IN ( SELECT t.id
                    FROM hdb_catalog.hdb_cron_events t
                    WHERE ( t.status = 'scheduled'
                            and (
                             (t.next_retry_at is NULL and t.scheduled_time <= now()) or
                             (t.next_retry_at is not NULL and t.next_retry_at <= now())
                            )
                          )
                    FOR UPDATE SKIP LOCKED
                    )
      RETURNING id, trigger_name, scheduled_time, tries, created_at
      |] () True
  where uncurryEvent (i, n, st, tries, createdAt) = CronEventPartial i n st tries createdAt

getOneOffScheduledEvents :: Q.TxE QErr [OneOffScheduledEvent]
getOneOffScheduledEvents = do
  map uncurryOneOffScheduledEvent <$> Q.listQE defaultTxErrorHandler [Q.sql|
      UPDATE hdb_catalog.hdb_scheduled_events
      SET status = 'locked'
      WHERE id IN ( SELECT t.id
                    FROM hdb_catalog.hdb_scheduled_events t
                    WHERE ( t.status = 'scheduled'
                            and (
                             (t.next_retry_at is NULL and t.scheduled_time <= now()) or
                             (t.next_retry_at is not NULL and t.next_retry_at <= now())
                            )
                          )
                    FOR UPDATE SKIP LOCKED
                    )
      RETURNING id, webhook_conf, scheduled_time, retry_conf, payload, header_conf, tries, comment, created_at
      |] () False
  where
    uncurryOneOffScheduledEvent ( eventId
                                , webhookConf
                                , scheduledTime
                                , retryConf
                                , payload
                                , headerConf
                                , tries
                                , comment
                                , createdAt) =
      OneOffScheduledEvent eventId
                           scheduledTime
                           tries
                           (Q.getAltJ webhookConf)
                           (Q.getAltJ payload)
                           (Q.getAltJ retryConf)
                           (Q.getAltJ headerConf)
                           comment
                           createdAt


liftExceptTIO :: (MonadError e m, MonadIO m) => ExceptT e IO a -> m a
liftExceptTIO m = liftEither =<< liftIO (runExceptT m)

newtype ScheduledEventIdArray =
  ScheduledEventIdArray { unScheduledEventIdArray :: [ScheduledEventId]}
  deriving (Show, Eq)

instance Q.ToPrepArg ScheduledEventIdArray where
  toPrepVal (ScheduledEventIdArray l) = Q.toPrepValHelper PTI.unknown encoder $ l
    where
      -- 25 is the OID value of TEXT, https://jdbc.postgresql.org/development/privateapi/constant-values.html
      encoder = PE.array 25 . PE.dimensionArray foldl' (PE.encodingArray . PE.text_strict)

unlockCronEvents :: [ScheduledEventId] -> Q.TxE QErr Int
unlockCronEvents scheduledEventIds =
   (runIdentity . Q.getRow) <$> Q.withQE defaultTxErrorHandler
   [Q.sql|
     WITH "cte" AS
     (UPDATE hdb_catalog.hdb_cron_events
     SET status = 'scheduled'
     WHERE id = ANY($1::text[]) and status = 'locked'
     RETURNING *)
     SELECT count(*) FROM "cte"
   |] (Identity $ ScheduledEventIdArray scheduledEventIds) True

unlockOneOffScheduledEvents :: [ScheduledEventId] -> Q.TxE QErr Int
unlockOneOffScheduledEvents scheduledEventIds =
   (runIdentity . Q.getRow) <$> Q.withQE defaultTxErrorHandler
   [Q.sql|
     WITH "cte" AS
     (UPDATE hdb_catalog.hdb_scheduled_events
     SET status = 'scheduled'
     WHERE id = ANY($1::text[]) AND status = 'locked'
     RETURNING *)
     SELECT count(*) FROM "cte"
   |] (Identity $ ScheduledEventIdArray scheduledEventIds) True

unlockAllLockedScheduledEvents :: Q.TxE QErr ()
unlockAllLockedScheduledEvents = do
  Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_cron_events
          SET status = 'scheduled'
          WHERE status = 'locked'
          |] () True
  Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_scheduled_events
          SET status = 'scheduled'
          WHERE status = 'locked'
          |] () True
