---
title: "PG 中的 builtin function"
hidden: false
tags: ["Postgresql/Greenplum"]
---


PG 的 CREATE FUNCTION 支持用户在 create function 时使用 language internal. 此时 AS 子句中跟着的是 PG builtin function 的函数名. 如下所示:

```sql
CREATE FUNCTION myfloat4abs(float4) RETURNS float4 LANGUAGE internal AS 'float4abs'
```

这里 float4abs 是 PG 内建函数之一. 根据 PG 代码中注释可以看到, PG 之所以提供此特性给用户, 是希望用户可以在需要的时候为 builtin function 起一个 alias.

但这也给了我们另外一种在不改变 CATALOG_VERSION 的前提下新增一些 builtin function 的途径. 我们都知道正常情况下新增 builtin function 需要同时变更 catalog version, 这意味着这些新增 builtin function 只能对 initdb 之后的数据库也有效, 对于存量的数据库将无法使用到. 如下我们先介绍下 builtin function 组织. 

所有 builtin function 的声明都在 pg_proc.h 文件中. 在构建时, Gen_fmgrtab.pl 会根据 pg_proc.h 为每一个 builtin function 生成一个 FmgrBuiltin 结构体来描述该 builtin function, 所有 builtin function FmgrBuiltin 结构体都存放在 fmgr_builtins 中, 按照 FmgrBuiltin::foid 从小到大存放着. 在 FmgrBuiltin 中, 存放着 builtin function 对应 CREATE FUNCTION 语句的一些信息. 如 foid, 存放着对应 CREATE FUNCTION 创建的 function 在 pg_proc 中对应的 oid. 某些时候一个 builtin function 在 pg_proc.h 中可能会对应着多个 CREATE FUNCTION 语句, 如 float4abs 对应着 `CREATE FUNCTION float4abs` 以及 `CREATE FUNCTION abs`, 这种情况下每个 CREATE FUNCTION 语句都对应着一个 FmgrBuiltin 结构体.

这里再以 `SELECT myfloat4abs(3.3);` 为例介绍下 PG 函数求值链路. 之后以此演示下如何在不改变 CATALOG_VERSION 的前提下新增一些 builtin function. 这里函数求值的入口是 `ExecEvalFunc()`, 其内最终会调用到 `fmgr_info_cxt_security` 来填充 FmgrInfo 结构, 该结构将用于后续实际的函数调用. 在 `fmgr_info_cxt_security` 中, 会首先查看 functionId 是否在 fmgr_builtins 中, 若在则直接使用 FmgrBuiltin 中信息来填充 FmgrInfo, 省去了查询 pg_proc. 如果不在 fmgr_builtins, 则会查询 pg_proc 拉出相应信息, 此时若 proc language 是 INTERNALlanguageId, 那么 PG 便认为 prosrc 中存放着 builtin function name, 便会再次在 fmgr_builtins 中查找同名 builtin function, 这里只会使用 FmgrBuiltin::func 字段, 来填充 FmgrInfo::fn_addr, FmgrInfo 其他字段仍然是根据 pg_proc 内容来填充的. 

也即意味着如果我们基于 builtin function 使用了 `CREATE FUNCTION ... LANGUAGE internal` 创建了额外的 alias, 那么在调用 alias 时, `FunctionCallInfo::flinfo` 存放的是 alias function 相关元信息. 以此信息可以在 builtin function 的入口判断本次调用来源. 比如在 [PR9934](https://github.com/greenplum-db/gpdb/pull/9934) 中, 考虑到我们云上已经有了很多存量实例, 新增的 function pg_get_partition_path 在这些实例上无法使用, 因此我们将 pg_get_partition_path 加入到了 pg_get_partition_def 函数中, 如下:

```c
static bool
is_pg_get_partition_path(FunctionCallInfo fcinfo)
{
	if (fcinfo->flinfo == NULL || !OidIsValid(fcinfo->flinfo->fn_oid))
		return false;
	const char *funcname = get_func_name(fcinfo->flinfo->fn_oid);
	return funcname != NULL && strcmp(funcname, "pg_get_partition_path") == 0;
}

/* This function will be called via pg_get_partition_path. */
Datum
pg_get_partition_def(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);
	char 	   *str;
	if (is_pg_get_partition_path(fcinfo))
		PG_RETURN_DATUM(pg_get_partition_path(fcinfo));
  // ...
}
```

之后再运行如下 SQL 来创建 pg_get_partition_path 函数:

```sql
CREATE FUNCTION pg_catalog.pg_get_partition_path(oid, text, text) RETURNS text LANGUAGE internal STABLE STRICT AS 'pg_get_partition_def';
```
