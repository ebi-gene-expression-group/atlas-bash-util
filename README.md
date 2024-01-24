# Bash utilities used by Expression Atlas [![Anaconda-Server Badge](https://anaconda.org/ebi-gene-expression-group/atlas-bash-util/badges/version.svg)](https://anaconda.org/ebi-gene-expression-group/atlas-bash-util)

This is a module factored out of legacy code to provide common bash utilities to Atlas scripts. 

## Installation

This package can be installed via Bioconda:

```
conda install -c ebi-gene-expression-group atlas-bash-util
```

## Usage

### Generic routines

Any of the bash functions from generic_routines.sh can be accessed via the `atlas-bash-utils` accessor script, like:

```
> atlas-bash-util capitalize_first_letter foo
Foo
```

### LSF wrapper

This package also contains functions to facilate submissions to our LSF compute cluster, principally this is for interactive waiting for jobs to run and checking of errors.

Usage:

```
atlas-lsf -h
Usage: ./atlas-lsf [ -c <command string> ] \
    [ -w <working directory, default current working directory> ] \
    [ -m <memory in Mb, defaults to cluster default> ] \
    [ -p <number of cores, defaults to cluster default> ] \
    [ -j <job name, defaults to cluster default> ] \
    [ -g <job group name, defaults to cluster default> ] \
    [ -l <log prefix, no logs written by default> ] \
    [ -e <clean up log files after monitored run? Defaults to no> ] \
    [ -m <monitor submitted job? Defaults to yes> ] \
    [ -f <poll frequency in seconds if job is monitored. Defaults to 10.> ] \
    [ -q <lsf queue, defaults to cluster default ]
    [ -v <name of the conda environment in which to run the job> ]
```

Examples:

Submit a job but don't keep track of it:

```
> atlas-lsf -c "sleep 10" -f 2 -n no
Job submission succeeded, received job ID 5308898
```

Submit and monitor a job, see that it completes without error:

```
 > atlas-lsf -c "sleep 10" -f 2 -s status
Job submission succeeded, received job ID 5308537
Starting status is PEND...
Status is now RUN.....
Status is now DONE

> echo $?
0
```

Submit and monitor a job and see that it fails:

```
> atlas-lsf -c "sleep 10; exit 5" -f 2 -s status
Job submission succeeded, received job ID 5308510
Starting status is PEND...
Status is now RUN.....
Status is now EXIT

Command "sleep 10; exit 5" failed, status EXIT
> echo $?
1
```

View STDOUT and STDERR of the job as it runs (this is the default style):

```
> ./atlas-lsf -c "echo ONE;sleep 5;echo TWO;echo ERROR 1>&2;sleep 5;echo THREE;echo BOO! 1>&2;" -l $(pwd)/foo -f 2 -s std_out_err
Job submission succeeded, received job ID 5316059
Monitor style: std_out_err
==> /path/to/foo.err <==

==> /path/to/foo.out <==

==> /path/to/foo.err <==
ERROR

==> /path/to/foo.out <==
ONE
TWO

==> /path/to/foo.err <==
BOO!

==> /path/to/foo.out <==
THREE

------------------------------------------------------------
Sender: LSF System <lsf@foo-cluster-47-01>
Subject: Job 5316059: <echo ONE;sleep 5;echo TWO;echo ERROR 1>&2;sleep 5;echo THREE;echo BOO! 1>&2> in cluster <cluster> Done

Job <echo ONE;sleep 5;echo TWO;echo ERROR 1>&2;sleep 5;echo THREE;echo BOO! 1>&2> was submitted from host <foo-cluster-08-04> by user <user> in cluster <cluster> at Thu Dec  2 17:36:28 2021
Job was executed on host(s) <foo-cluster-47-01>, in queue <standard>, as user <user> in cluster <cluster> at Thu Dec  2 17:36:29 2021
</homes/user> was used as the home directory.
</path/to> was used as the working directory.
Started at Thu Dec  2 17:36:29 2021
Terminated at Thu Dec  2 17:36:40 2021
Results reported at Thu Dec  2 17:36:40 2021

Your job looked like:

------------------------------------------------------------
# LSBATCH: User input
echo ONE;sleep 5;echo TWO;echo ERROR 1>&2;sleep 5;echo THREE;echo BOO! 1>&2;
------------------------------------------------------------

Successfully completed.

Resource usage summary:

    CPU time :                                   0.04 sec.
    Max Memory :                                 6 MB
    Average Memory :                             6.00 MB
    Total Requested Memory :                     -
    Delta Memory :                               -
    Max Swap :                                   -
    Max Processes :                              3
    Max Threads :                                4
    Run time :                                   10 sec.
    Turnaround time :                            12 sec.

The output (if any) is above this job summary.



PS:

Read file </path/to/foo.err> for stderr output of this job.
```

Submit a job that should run in a conda environment:

```
> atlas-lsf -v myenv -c "echo $CONDA_PREFIX > myenv.txt" -f 2 -n no
Job submission succeeded, received job ID 2711148

>cat myenv.txt
/hps/software/users/GTL/user/miniconda3/envs/myenv
```

### SLURM wrapper

This package also contains functions to facilate submissions to our LSF compute cluster, principally this is for interactive waiting for jobs to run and checking of errors.

Usage:

```
./slurm/atlas-slurm -h
Usage: ./slurm/atlas-slurm [ -c <command string> ] \
           [ -w <working directory, default current working directory> ] \
           [ -m <memory in Mb, defaults to cluster default> ] \
           [ -p <number of cores, defaults to cluster default> ] \
           [ -j <job name, defaults to cluster default> ] \
           [ -g <job group name, defaults to cluster default> ] \
           [ -l <log prefix, no logs written by default> ] \
           [ -e <clean up log files after monitored run? Defaults to no> ] \
           [ -n <monitor submitted job? Defaults to yes> ] \
           [ -o <with -l, print standard output content? Defaults to no> ] \
           [ -s <monitor style: 'status' for job status updates on polling, 'std_out_err' to report ongoing content of logs (where used). Defaults to std_out_err> ] \
           [ -f <poll frequency in seconds if job is monitored. Defaults to 10.> ] \
           [ -q <slurm queue, defaults to cluster default> ] \
           [ -u <suppress logging output? Default: no> ] \
           [ -v <name of the conda environment in which to run the job> ]

```
Here, memory is a mandatary field for SLURM submission. If memory is not specified with `-m` flag, it will use 4000Mb by default. If queue/partition is not specified it will use production by default. 

Here, CPU-time is a mandatary field for SLURM submission. It will allocate maximum allowed time for the partition/queue by default.

Examples:


Submit and monitor a job, see that it completes without error:

```
 > slurm/atlas-slurm -c "sleep 10" -f 2 -s status -m 2000
