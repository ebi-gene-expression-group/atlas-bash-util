# Bash utilities used by Expression Atlas

This is a module factored out of legacy code to provide common bash utilities to Atlas scripts. 

## Usage

Any of the bash functions from generic_routines.sh can be accessed via the `atlas-bash-utils` accessor script, like:

```
> atlas-bash-util capitalize_first_letter foo
Foo
```
