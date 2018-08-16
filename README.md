# bom-events

Framework for reacting to user/system events

## NAME

BOM::Event::Actions::Customerio - contains method related to www.customerio.com, which is used by the marketing department.

BOM::Event::Listener - A infinite loop that dequeue and process the task every 30 seconds.

BOM::Event::Process - A class that does the binding to the underlying functions, where the actions are located under **lib/BOM/Event/Actions/\***.

## SYNOPSIS

### Enqueue/Emit a task

```
use BOM::Platform::Event::Emitter;

BOM::Platform::Event::Emitter::emit(
    'task_name',
    {
        # data to be passed to the processor.
    });
```

The tasks will be allocated to different instances of the queue based on the task_name, the allocation happens in BOM::Platform::Event::Emitter::emit;.

### Starting a queue
```
use BOM::Event::Listener;

BOM::Event::Listener::run('queue_to_start');
```

This will start an instance of queue which finishes the task every 30 seconds.

## Test
```
# run all test scripts
make test
# run one script
prove t/BOM/user.t
# run one script with perl
perl -MBOM::Test t/BOM/01_event_workflow.t
```

## DESCRIPTION

bom-events is for reducing the load on servers by pushing tasks onto a redis queue.

bom-events works much like bom-rpc, it is allowed to use/import module from any repositories with the only exception being bom-rpc, this check is being imposed in **t/structure.t**.

no repositories should depend on bom-events; reason for this is as follow:

1. To avoid structural circular dependency issues.

2. To have a self contained collection of events related functions, so that it does not scatter all over the repositories

