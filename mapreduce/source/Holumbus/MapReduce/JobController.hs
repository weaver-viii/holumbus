-- ----------------------------------------------------------------------------
{- |
  Module     : Holumbus.MapReduce.JobController
  Copyright  : Copyright (C) 2008 Stefan Schmidt
  License    : MIT

  Maintainer : Stefan Schmidt (stefanschmidt@web.de)
  Stability  : experimental
  Portability: portable
  Version    : 0.1


-}
-- ----------------------------------------------------------------------------

{-# OPTIONS -fglasgow-exts #-}
module Holumbus.MapReduce.JobController
(

  TaskSendResult(..)
, TaskSendFunction

, JobController

, printJobController

-- * Creation and Destruction
, newJobController
, closeJobController
, setFileSystemToJobController
, setTaskSendHook
, setMapActions
, setReduceActions

-- * Job Controller 
, startJobController
, stopJobController
, isJobControllerRunning
, singleStepJobControlling

-- * performing MapReduce-Jobs
-- , startJob
-- , stopJob
, performJob

-- * handling Task-Responses
, setTaskCompleted
, setTaskError
)
where

import qualified Control.Exception as E
import           Control.Concurrent
import           Control.Monad
import qualified Data.ByteString.Lazy as B
import           Data.Maybe
import           Data.Time
import           Data.Typeable
import qualified Data.Map as Map
import qualified Data.Set as Set
import           System.Log.Logger

import           Holumbus.MapReduce.Types
import qualified Holumbus.FileSystem.FileSystem as FS
import qualified Holumbus.Data.AccuMap as AMap
import qualified Holumbus.Data.MultiMap as MMap


localLogger :: String
localLogger = "Holumbus.MapReduce.JobController"

cycleLogger :: String
cycleLogger = "Holumbus.MapReduce.JobController.cycle"

-- ----------------------------------------------------------------------------
--
-- ----------------------------------------------------------------------------


newJobData  
  :: JobControllerData -> JobInfo
  -> IO (JobControllerData, JobData, MVar JobResult)
newJobData jcd info
  = do
    t <- getCurrentTime
    mVar <- newEmptyMVar
    let jrc = JobResultContainer mVar 
    let jid = jcd_NextJobId jcd
    let jcd' = jcd { jcd_NextJobId = (jid+1) }
    let pairs = zip (iterate (+1) 1) (map (\i -> [i]) (ji_Input info))
    let accuMap = AMap.fromList pairs 
    let outputMap = Map.insert JSIdle accuMap Map.empty
    return (jcd', JobData jid JSIdle outputMap info t t jrc, mVar)

newTaskData 
  :: JobControllerData 
  -> JobId -> TaskType -> TaskState -> B.ByteString -> [FunctionData] -> FunctionName -> TaskOutputType 
  -> IO (JobControllerData, TaskData)
newTaskData jcd jid tt ts opt i a ot
  = do
    let tid = jcd_NextTaskId jcd
    let jcd' = jcd { jcd_NextTaskId = (tid+1) }
    return (jcd', TaskData jid tid tt ts opt i [] ot a) 
    
data TaskSendResult = TSRSend | TSRNotSend | TSRError
  deriving (Show, Eq, Ord, Enum)    
    
-- ----------------------------------------------------------------------------
--
-- ----------------------------------------------------------------------------

intersections :: Ord a => [Set.Set a] -> Set.Set a  
intersections [] = Set.empty
intersections (s:ss) = foldl Set.intersection s ss 


mapAccumLM
  :: (Monad m) 
  => (acc -> x -> m (acc, y)) -- Function of of input list
                               -- and accumulator, returning new
                               -- accumulator and of result list
  -> acc                       -- Initial accumulator 
  -> [x]                       -- Input list
  -> m (acc, [y])             -- Final accumulator and result list
mapAccumLM _ s [] = return (s, [])
mapAccumLM f s (x:xs) 
  = do
    (s', y ) <- f s x
    (s'',ys) <- mapAccumLM f s' xs
    return (s'',y:ys)




type TaskSendFunction = TaskData -> IO (TaskSendResult)

dummyTaskSendFunction :: TaskData -> IO (TaskSendResult)
dummyTaskSendFunction _ = return TSRSend


type JobMap         = Map.Map JobId JobData
type TaskMap        = Map.Map TaskId TaskData
    
type StateJobIdMap  = MMap.MultiMap JobState JobId

type JobIdTaskIdMap = MMap.MultiMap JobId TaskId
type TypeTaskIdMap  = MMap.MultiMap TaskType TaskId
type StateTaskIdMap = MMap.MultiMap TaskState TaskId
   
    
data JobControlFunctions = JobControlFunctions {
    jcf_TaskSend :: TaskSendFunction
  }
instance Show JobControlFunctions where
  show _ = "JobControlFunctions"

    
data JobControllerData = JobControllerData {
  -- internal
    jcd_ServerThreadId :: Maybe ThreadId
  , jcd_ServerDelay    :: Int
  , jcd_FileSystem     :: Maybe FS.FileSystem
  -- control
  -- , jcd_MaxRunningJobs :: Int
  , jcd_NextJobId      :: JobId
  , jcd_NextTaskId     :: TaskId
  , jcd_Functions      :: JobControlFunctions
  
  , jcd_MapActionMap   :: MapActionMap
  , jcd_ReduceActionMap :: ReduceActionMap
  
  -- job control
  , jcd_JobMap         :: ! JobMap
  , jcd_TaskMap        :: ! TaskMap
  , jcd_StateJobIdMap  :: ! StateJobIdMap
  , jcd_JobIdTaskIdMap :: ! JobIdTaskIdMap
  , jcd_TypeTaskIdMap  :: ! TypeTaskIdMap
  , jcd_StateTaskIdMap :: ! StateTaskIdMap
  } deriving (Show)




type JobController = MVar JobControllerData

printJobController :: JobController -> IO String
printJobController jc
  = withMVar jc $ \jcd -> return $ show jcd


data JobControllerException
  = KillServerException
  deriving (Show, Typeable)

-- ----------------------------------------------------------------------------
-- Contruction / Destruction 
-- ----------------------------------------------------------------------------

defaultJobControllerData :: JobControllerData
defaultJobControllerData = jcd
  where
  jcd = JobControllerData
    Nothing
    1000000
    Nothing
    1
    1
    jcf
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    MMap.empty
    MMap.empty
    MMap.empty
    MMap.empty
  jcf = JobControlFunctions
    dummyTaskSendFunction

newJobController :: IO JobController
newJobController
  = do
    let jcd = defaultJobControllerData
    jc <- newMVar jcd
    return jc 

closeJobController :: JobController -> IO ()
closeJobController jc
  = do
    stopJobController jc


setFileSystemToJobController :: FS.FileSystem -> JobController -> IO ()
setFileSystemToJobController fs jc
  = modifyMVar jc $
    \jcd -> return $ (jcd { jcd_FileSystem = Just fs }, ())


setTaskSendHook :: TaskSendFunction -> JobController -> IO ()
setTaskSendHook f jc
  = do
    modifyMVar jc $
      \jcd ->
      do
      let funs = jcd_Functions jcd
      let funs' = funs { jcf_TaskSend = f }
      return (jcd { jcd_Functions = funs' }, ())


setMapActions :: MapActionMap -> JobController -> IO ()
setMapActions mm jc
  = modifyMVar jc $ \jcd -> return (jcd {jcd_MapActionMap = mm }, ())


setReduceActions :: ReduceActionMap -> JobController -> IO ()
setReduceActions rm jc
  = modifyMVar jc $ \jcd -> return (jcd {jcd_ReduceActionMap = rm }, ())


-- ----------------------------------------------------------------------------
-- server functions
-- ----------------------------------------------------------------------------

startJobController :: JobController -> IO ()
startJobController jc
  = do
    modifyMVar jc $ 
      \jcd -> 
      do
      thd <- case (jcd_ServerThreadId jcd) of
        (Just i) -> return i
        (Nothing) ->
          do
          i <- forkIO $ doProcessing jc True
          return i
      return (jcd {jcd_ServerThreadId = (Just thd)}, ())



stopJobController :: JobController -> IO ()
stopJobController jc
  = do
    modifyMVar jc $ 
      \jcd -> 
      do
      case (jcd_ServerThreadId jcd) of
        (Nothing) -> return ()
        (Just i) -> 
          do
          E.throwDynTo i KillServerException
          yield
          return ()
      return (jcd {jcd_ServerThreadId = Nothing}, ())


isJobControllerRunning :: JobController -> IO Bool
isJobControllerRunning jc
  = withMVar jc $
      \jcd ->
      do
      case (jcd_ServerThreadId jcd) of
        (Nothing) -> return True
        (Just _)  -> return False


singleStepJobControlling :: JobController -> IO ()
singleStepJobControlling jc
  = do
    singleStepAllowed <- withMVar jc $ 
      \jcd -> 
      do
      case (jcd_ServerThreadId jcd) of
        (Nothing) -> return True
        (Just _)  -> return False
    if singleStepAllowed then doProcessing jc False else return ()

-- ----------------------------------------------------------------------------
-- private functions
-- ----------------------------------------------------------------------------

-- | get the JobIds, they can be filtered by JobState, if the filter is empty
--   all Jobs are returned.
getJobIds :: [JobState] -> JobControllerData -> [JobId]
getJobIds states jcd = Set.toList $ MMap.filterElements states (jcd_StateJobIdMap jcd)


-- | get the TaskIds, they can be filtered by JobId, TaskType and TaskState, if
--   a filter is empty, this attribute is not taken into account
getTaskIds :: [JobId] -> [TaskType] -> [TaskState] -> JobControllerData -> [TaskId]
getTaskIds jobs types states jcd = Set.toList $ intersections sets
  where
  jobSelected   = MMap.filterElements jobs (jcd_JobIdTaskIdMap jcd)
  typeSelected  = MMap.filterElements types (jcd_TypeTaskIdMap jcd)
  stateSelected = MMap.filterElements states (jcd_StateTaskIdMap jcd)
  sets = [jobSelected, typeSelected, stateSelected]


allTasksFinished :: JobControllerData -> JobId -> Bool
allTasksFinished jcd jid = null notFinishedTasks
  where
    notFinishedTasks = getTaskIds [jid] [] [TSIdle, TSInProgress, TSCompleted] jcd



-- | adds a Job to the JobControllerData for execution
addJob :: JobData -> JobControllerData -> JobControllerData
addJob jd jcd = jcd { jcd_JobMap = jm', jcd_StateJobIdMap = sjm' }
  where
  jm' = Map.insert (jd_JobId jd) jd (jcd_JobMap jcd)
  sjm' = MMap.insert (jd_State jd) (jd_JobId jd) (jcd_StateJobIdMap jcd)


changeJobState :: JobId -> JobState -> JobControllerData -> JobControllerData
changeJobState jid js jcd = changeJobState' (Map.lookup jid (jcd_JobMap jcd))
  where
  changeJobState' (Nothing) = jcd
  changeJobState' (Just jd) = jcd { jcd_JobMap = jm', jcd_StateJobIdMap = sjm' }
    where
    jd' = jd { jd_State = js }  -- change JobData
    js' = jd_State jd           -- get old state
    jm' = Map.insert jid jd' (jcd_JobMap jcd) -- change JobData
    sjm' = MMap.insert js jid $ MMap.deleteElem js' jid (jcd_StateJobIdMap jcd) -- change StateJobIdMap


updateJob :: JobData -> JobControllerData -> JobControllerData
updateJob jd jcd = addJob jd $ maybe (jcd) (\_ -> changeJobState jid js jcd) maybeOldJob
  where
    maybeOldJob = (Map.lookup jid (jcd_JobMap jcd))
    jid = jd_JobId jd
    js = jd_State jd


addOutputToJob :: [(Int,[FunctionData])] -> JobData -> JobData
addOutputToJob outList jd = jd { jd_OutputMap = outputmap' }  
  where
  outAccu    = AMap.fromList outList
  state      = jd_State jd
  outputmap  = jd_OutputMap jd
  outputmap' = Map.insertWith (\m1 m2 -> AMap.union m1 m2) state outAccu outputmap 

addTask :: JobControllerData -> TaskData -> JobControllerData
addTask jcd td= jcd { jcd_TaskMap = tm', jcd_JobIdTaskIdMap = jtm', jcd_TypeTaskIdMap = ttm', jcd_StateTaskIdMap = stm' }
  where
    tid = td_TaskId td
    tm' = Map.insert tid td (jcd_TaskMap jcd)
    jtm' = MMap.insert (td_JobId td) tid (jcd_JobIdTaskIdMap jcd)
    ttm' = MMap.insert (td_Type td) tid (jcd_TypeTaskIdMap jcd)
    stm' = MMap.insert (td_State td) tid (jcd_StateTaskIdMap jcd)


changeTaskState :: TaskId -> TaskState -> JobControllerData -> JobControllerData
changeTaskState tid ts jcd = changeTaskState' (Map.lookup tid (jcd_TaskMap jcd))
  where
  changeTaskState' (Nothing) = jcd
  changeTaskState' (Just td) = 
    if isChangeTaskStateAllowed ts (td_State td)
      then jcd { jcd_TaskMap = tm', jcd_StateTaskIdMap = stm' }
      else jcd
    where
    td' = td { td_State = ts }  -- change TaskData
    ts' = td_State td           -- get old state
    tm' = Map.insert tid td' (jcd_TaskMap jcd) -- change TaskData
    stm' = MMap.insert ts tid $ MMap.deleteElem ts' tid (jcd_StateTaskIdMap jcd) -- change StateTaskIdMap


-- | newState oldState
isChangeTaskStateAllowed :: TaskState -> TaskState -> Bool
-- only Error-Tasks can be reset to idle
isChangeTaskStateAllowed TSIdle       t = Set.member t $ Set.fromList [TSError]
-- inProgress only from an idle Tasks
isChangeTaskStateAllowed TSInProgress t = Set.member t $ Set.fromList [TSIdle]
-- completed only idle and inprogress
isChangeTaskStateAllowed TSCompleted  t = Set.member t $ Set.fromList [TSIdle, TSInProgress]
-- finished all but not error
isChangeTaskStateAllowed TSFinished   t = Set.member t $ Set.fromList [TSIdle, TSInProgress, TSCompleted]
-- we can always set a task to error
isChangeTaskStateAllowed TSError      _ = True
-- otherwise false (there are no other cases)
-- isChangeTaskStateAllowed _ _ = False

updateTaskOutput :: TaskId -> [(Int, [FunctionData])] -> JobControllerData -> JobControllerData
updateTaskOutput _ [] jcd = jcd
updateTaskOutput tid o jcd = updateTaskOuput' (Map.lookup tid (jcd_TaskMap jcd))
  where
  updateTaskOuput' (Nothing) = jcd
  updateTaskOuput' (Just td) = jcd { jcd_TaskMap = tm' }
    where
    td' = td { td_Output = o }  -- change TaskData
    tm' = Map.insert tid td' (jcd_TaskMap jcd) -- change TaskData


-- ----------------------------------------------------------------------------
-- Info an Debug
-- ----------------------------------------------------------------------------


-- ----------------------------------------------------------------------------
-- Task Controlling
-- ----------------------------------------------------------------------------


startJob 
  :: JobInfo -> JobController -> IO (JobId, MVar JobResult)
startJob ji jc
  = do
    modifyMVar jc $
      \jcd ->
      do
      -- test the job info... we don't want false jobs
      -- let (b, m) = testJobInfo ji (jcd_MapActionMap jcd) (jcd_ReduceActionMap jcd)
      -- if b 
      --   then do
      (jcd',jd, jr) <- newJobData jcd ji
      return (addJob jd jcd', (jd_JobId jd, jr))
      --   else do
      --    return (jcd, Left m)

{-
stopJob :: JobId -> JobController -> IO ()
stopJob _ _
  = do
    undefined
-}

performJob
  :: JobInfo -> JobController -> IO JobResult
performJob ji jc
  = do
    -- start the Job
    (_, mjr) <- startJob ji jc
    -- wait until the result is ready
    withMVar mjr $ \jr -> return jr

-- ----------------------------------------------------------------------------
-- Task Processing
-- ----------------------------------------------------------------------------


doProcessing :: JobController -> Bool -> IO ()
doProcessing jc loop
  = do
    E.catchDyn (doProcessing' jc loop)
      handler
    where
      handler :: JobControllerException -> IO ()
      handler err = errorM cycleLogger $ "doProcessing: " ++ (show err)
      doProcessing' jc' loop'
        = do
          handleTasks jc'
          handleJobs jc'
          if loop' 
            then do
              delay <- withMVar jc' (\jcd -> return $ jcd_ServerDelay jcd)
              threadDelay delay
              doProcessing' jc' loop'
            else
              return ()



-- ----------------------------------------------------------------------------
-- Process Tasks
-- ----------------------------------------------------------------------------

toNextTaskState :: JobControllerData -> TaskData -> JobControllerData
toNextTaskState jcd td = changeTaskState (td_TaskId td) (getNextTaskState (td_State td)) jcd 

-- | the send task doesn't block, because a timeout causes the whole job
--   controller to pause, we don't want this
sendTask :: JobController -> TaskData -> IO ()
sendTask jc td
  = do
    -- own thread for this... so it is non-blocking
    forkIO $ 
      do
      yield
      -- get the sendFunction (just read it)
      sendFunction <- withMVar jc $
        \jcd -> return $ jcf_TaskSend $ jcd_Functions jcd
      -- execute the send function (this might timeout or block)
      sendResult <- sendFunction td
      -- set the task in the correct state
      case sendResult of
        (TSRSend) ->
          do
          setTaskInProgress jc td
        (TSRNotSend) ->
          do
          -- Task already in idle
          return ()
        (TSRError) ->
          do
          setTaskError jc td
    return ()


finishTask :: JobControllerData -> TaskData -> JobControllerData
finishTask jcd td = toNextTaskState jcd' td
  where
    jd  = fromJust $ Map.lookup (td_JobId td) (jcd_JobMap jcd)
    jd' = addOutputToJob (td_Output td) jd  
    jcd' = updateJob jd' jcd 


handleTasks :: JobController -> IO ()
handleTasks jc
  = modifyMVar jc $
      \jcd ->
      do
      infoM cycleLogger "processing Tasks:"
      -- get all runnning jobs (not idle...)
      let runningJobs = getJobIds [JSMap, JSCombine, JSReduce] jcd
      infoM cycleLogger $ "running Jobs:" ++ show runningJobs
      -- get all idle tasks
      let idleTasks = getTaskIds runningJobs [] [TSIdle] jcd
      infoM cycleLogger $ "idle Tasks:" ++ show idleTasks
      let idleTaskDatas = mapMaybe (\tid -> Map.lookup tid (jcd_TaskMap jcd)) idleTasks
      -- send all idle Tasks (non-blocking)
      mapM (sendTask jc) idleTaskDatas
      -- get all completed Tasks
      let completedTasks = getTaskIds runningJobs [] [TSCompleted] jcd
      let completedTaskDatas = mapMaybe (\tid -> Map.lookup tid (jcd_TaskMap jcd)) completedTasks
      -- inProgressTasks = getTaskIds runningJobs [] [TSInProgress] jcd
      let jcd' = foldl finishTask jcd completedTaskDatas
      return (jcd',())


-- ----------------------------------------------------------------------------
-- Process Jobs
-- ----------------------------------------------------------------------------

toNextJobState :: JobControllerData -> JobData -> JobControllerData
toNextJobState jcd jd = changeJobState (jd_JobId jd) (getNextJobState (jd_State jd)) jcd

-- toIdleTaskState :: JobControllerData -> TaskData -> JobControllerData
-- toIdleTaskState jcd td = changeTaskState (td_TaskId td) TSIdle jcd

toInProgressTaskState :: JobControllerData -> TaskData -> JobControllerData
toInProgressTaskState jcd td = changeTaskState (td_TaskId td) TSInProgress jcd

toCompletedTaskState :: JobControllerData -> TaskData -> JobControllerData
toCompletedTaskState jcd td = updateTaskOutput tid o $ changeTaskState tid TSCompleted jcd
  where
  tid = td_TaskId td
  o = td_Output td

toErrorTaskState :: JobControllerData -> TaskData -> JobControllerData
toErrorTaskState jcd td = changeTaskState (td_TaskId td) TSError jcd


hasPhase :: JobData -> Bool
hasPhase jd = isJust $ getCurrentTaskAction jd


getCurrentTaskAction :: JobData -> Maybe FunctionName
getCurrentTaskAction jd = getTaskAction' (jd_Info jd) (jd_State jd)
  where
  getTaskAction' ji JSMap     = ji_MapAction ji
  getTaskAction' ji JSCombine = ji_CombineAction ji
  getTaskAction' ji JSReduce  = ji_ReduceAction ji 
  getTaskAction' _  _         = Nothing


getCurrentTaskOutputType :: JobData -> TaskOutputType
getCurrentTaskOutputType jd = getTaskOutputType' (jd_Info jd) (jd_State jd)
  where
  getTaskOutputType' ji JSMap     = maybe TOTList id (ji_MapOutputType ji)
  getTaskOutputType' ji JSCombine = maybe TOTList id (ji_CombineOutputType ji)
  getTaskOutputType' ji JSReduce  = maybe TOTText id (ji_ReduceOutputType ji)
  getTaskOutputType' _  _         = TOTList

{-
performPartition :: JobControllerData -> JobData -> [FunctionData] -> IO [FunctionData]
performPartition jcd jd bin
  = do
    let pmap = jcd_PartitionMap jcd
    let fn = getCurrentPartitionFunction jd
    let maybeP = dispatchPartitionFunction pmap fn
    let p = maybe (\t -> return t) id maybeP
    bout <- p bin
    return bout
-}

createTasks :: JobControllerData -> JobData -> IO JobControllerData
createTasks jcd jd
  = do
    let state = jd_State jd
    let outputMap = (jd_OutputMap jd)
    -- our input is the output of the previous state
    let inputAccu = maybe (AMap.empty) (id) $ Map.lookup (getPrevJobState state) outputMap
    if (hasPhase jd)
      then do
        let inputList = AMap.toList inputAccu                
        let jid = jd_JobId jd
        let a = fromJust $ getCurrentTaskAction jd
        let ot = getCurrentTaskOutputType jd
        let opts = ji_Option $ jd_Info jd
        let tt  = fromJust $ fromJobStatetoTaskType state
        -- create new tasks
        (jcd', taskDatas) <- mapAccumLM (\d (_,i) -> newTaskData d jid tt TSIdle opts i a ot) jcd inputList
        -- add task to controller
        let jcd'' = foldl addTask jcd' taskDatas        
        return jcd''
      else do
        -- there is no action in this state, so we copy the input to the output
        let outputMap' = Map.insert state inputAccu outputMap 
        let jd' = jd { jd_OutputMap = outputMap' }
        return $ updateJob jd' jcd


createResults :: JobControllerData -> JobData -> IO JobControllerData
createResults jcd jd
  = do
    let outputAccu = maybe (AMap.empty) (id) $ Map.lookup JSCompleted (jd_OutputMap jd)
    let outputList = AMap.toList outputAccu
    let (JobResultContainer mVarResult) = jd_Result jd
    let res = JobResult $ concat $ map (snd) outputList
    putMVar mVarResult res
    return jcd  


handleJobs :: JobController -> IO ()
handleJobs jc
  = modifyMVar jc $
      \jcd ->
      do
      -- get all working jobs (idle or running)
      infoM cycleLogger "processing Jobs"
      let workingJobs = getJobIds [JSIdle, JSMap, JSCombine, JSReduce] jcd
      infoM cycleLogger $ "working jobs:" ++ show workingJobs
      -- process only jobs, whose current phase is done
      let jobsWithoutTasks = filter (allTasksFinished jcd) workingJobs
      infoM cycleLogger $ "jobsWithoutTasks:" ++ show jobsWithoutTasks
      -- get the old jobdatas
      let oldJobDatas = mapMaybe (\jid -> Map.lookup jid (jcd_JobMap jcd)) jobsWithoutTasks
      debugM cycleLogger $ "oldJobDatas:\n" ++ show oldJobDatas
      -- change the job states to the next phase
      let jcd1 = foldl toNextJobState jcd oldJobDatas
      -- get the new jobdatas
      let newJobDatas = mapMaybe (\jid -> Map.lookup jid (jcd_JobMap jcd1)) jobsWithoutTasks
      debugM cycleLogger $ "newJobDatas:\n" ++ show newJobDatas
      -- create new tasks for each Job
      jcd2 <- foldM createTasks jcd1 newJobDatas
      
      -- get all completed Jobs
      let completedJobs = getJobIds [JSCompleted] jcd2
      infoM cycleLogger $ "completed Jobs:" ++ show completedJobs
      -- get the completed JobDatas
      let completedJobDatas = mapMaybe (\jid -> Map.lookup jid (jcd_JobMap jcd2)) completedJobs
      -- change the job states to the next phase
      let jcd3 = foldl toNextJobState jcd2 completedJobDatas
      -- get the new jobdatas
      let finishedJobDatas = mapMaybe (\jid -> Map.lookup jid (jcd_JobMap jcd3)) completedJobs
      -- create new tasks for each Job
      jcd4 <- foldM createResults jcd3 finishedJobDatas
      
      return (jcd4, ())




-- ----------------------------------------------------------------------------   
-- handling Task-Responses
-- ----------------------------------------------------------------------------

{-
setTaskIdle :: JobController -> TaskData -> IO ()
setTaskIdle jc td
  = do
    debugM localLogger $ "setTaskIdle: waiting... TaskId: " ++ show (td_TaskId td)
    modifyMVar jc $
      \jcd ->
      do
      debugM localLogger $ "setTaskIdle: setting... TaskId: " ++ show (td_TaskId td)
      let jcd' = toIdleTaskState jcd td
      return (jcd', ())
-}

setTaskInProgress :: JobController -> TaskData -> IO ()
setTaskInProgress jc td
  = do
    debugM localLogger $ "setTaskInProgress: waiting... TaskId: " ++ show (td_TaskId td)
    modifyMVar jc $
      \jcd ->
      do
      debugM localLogger $ "setTaskInProgress: setting... TaskId: " ++ show (td_TaskId td)
      let jcd' = toInProgressTaskState jcd td
      return (jcd', ())


setTaskCompleted :: JobController -> TaskData -> IO ()
setTaskCompleted jc td
  = do
    debugM localLogger $ "setTaskCompleted: waiting... TaskId: " ++ show (td_TaskId td)
    modifyMVar jc $
      \jcd ->
      do
      debugM localLogger $ "setTaskCompleted: setting... TaskId: " ++ show (td_TaskId td)
      let jcd' = toCompletedTaskState jcd td
      return (jcd', ())

    
setTaskError :: JobController -> TaskData -> IO ()
setTaskError jc td
  = do
    debugM localLogger $ "setTaskError: waiting... TaskId: " ++ show (td_TaskId td)
    modifyMVar jc $
      \jcd ->
      do
      debugM localLogger $ "setTaskError: setting... TaskId: " ++ show (td_TaskId td)
      let jcd' = toErrorTaskState jcd td
      return (jcd', ())
    