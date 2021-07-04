---
title: The KuiBaDB Column Storage
hidden: false
tags: ["KuiBaDB"]
---

The KuiBaDB Column Storage is heavily inspired by 'Hologres: A Cloud-Native Service for Hybrid Serving/Analytical Processing' and rocksdb. The first prototype design was completed on October 7, 2020, and the second edition was done on December 2020 after an in-depth study of rocksdb. THERE ARE A LOT OF RAW POINTERS IN ROCKSDB!!!

```
      +--------+    +--------+    +--------+
L0:   | 0001.m |    | 0002.m |    | 0003.m |
      +--------+    +--------+    +--------+

      +--------+    +--------+    +--------+  +--------+  +--------+
L1:   | 0004.m |    | 0005.m |    | 0006.m |  | 0007.m |  | 0008.m |
      +--------+    +--------+    +--------+  +--------+  +--------+

      +--------+    +--------+    +--------+  +--------+ +--------+ +--------+
L2:   | 0009.i |    | 000A.i |    | 000B.i |  | 000C.i | | 000D.i | | 000E.i |
      +--------+    +--------+    +--------+  +--------+ +--------+ +--------+
```

Each data file in L0/L1/L2 has a corresponding file that stores the mvcc information for each row, currently, there are xmin, xmax, and infomask in the mvcc information. The semantics of xmin, xmax and infomask are consistent with those in PostgreSQL.

-   L0 level is the writable area, new data will be writen here. The file in L0 can only be written by one statement at a time. We will create a new L0 file when necessary.

-   When the length of one file in L0 exceeds the specified threshold, it will be moved to L1 in the background. L0 and L1 files will use the same storage format and are uncompressed. All are used to maximize write throughput and reduce write latency.

-   Files in L2 are compressed and are sorted by the sort key of table, and they don't overlap with each other. We will merge L2 with L1 at the right time and generate a new set of L2 files, currently, the right time is as follow:

    -   When the query finds that there are too many files in L1.

    -   When the query finds too many dead rows in one file.

    -   User request, and so on...

Each table has a manifest that holds all the live files and their lengths, the disk layout of the manifest is as follow:

```
ver: 4bytes
pagelsn: 8bytes
num_of_l0: 4bytes
(file_no_l0_file: 4bytes + len_of_l0_file: 8bytes + rownum: 4bytes) * num_of_l0
num_of_l1: 4bytes
(file_no_l1_file: 4bytes + len_of_l1_file: 8bytes + rownum: 4bytes) * num_of_l1
num_of_l2: 4bytes
(file_no_l2_file: 4bytes + len_of_l2_file: 8bytes + rownum: 4bytes) * num_of_l2
crc32c: 4bytes
```

SuperVersion, the in-memory form for manifest, is defined as follow:

```rust
struct SuperVersion {
    l0: Vec<L0File>,
    l1: Vec<Mrc<L1File>>,
    l2: Vec<Mrc<L2File>>,
}

enum L0State {
    Unused,  // can be used by the next write.
    InUse,  // is being used by a statement.
    Moving,  // Will be moved to L1.
}

struct L0File {
    fileno: u32,
    len: AtomicU32,
    state: AtomicU32,  // see L0State
}

struct L1File {
    fileno: u32,
    len: u32,
}

struct L2File {
    fileno: u32,
    len: u32,
}

// Mrc, manually managed reference count, is very similar to Ref/Unref in rocksdb.
struct Mrc<T> {
}

struct TableMeta {
    sv: Mrc<SuperVersion>,
    mvcc: SharedBuffer<PageId, Page>,
}
```

TableMetaCache, `SharedBuffer<TableId, TableMeta>`, is used to save the mapping between the table and its SuperVersion. In RocksDB, SuperVersion of ColumnFamily is memory resident. but OLAP system may have many tables, we should support swapping the SuperVersion of some infrequently used tables out to disk.

# MVCC

Each data file in manifest has a corresponding file that stores the mvcc information for each row. The mvcc file is divided into blocks. The layout of mvcc block is defined as follows:

```
+--------------------------------------+
|page lsn: 8bytes, for full page image.|
+--------------------------------------+
|xmin: 8 bytes * NumOfRows             |
+--------------------------------------+
|xmax: 8 bytes * NumOfRows             |
+--------------------------------------+
|infomask: 8 bytes * NumOfRows         |
+--------------------------------------+
```

xmin, xmax are stored in columns so that we can perform visibility judgments in a vectorized manner.

All the mvcc blocks except the last block have the same number of rows, the number is specified by CREATE TABLE. We can quickly locate the position of xmin and xmax for a row according to its rowid in data file.

# Insert

1.  Get the SuperVersion from TableMetaCache, Superversion will be loaded from disk if necessary.
2.  Get an available L0File from SuperVersion, CAS-like atomic operations will be used here.
3.  Append data to the L0File. At present, we will write wal record here, but we can remove it. This requires us to sync every write, in this case, the data is wal. This is very similar to GP AOCS. In GP4.3, writes don't need wal record, because every write will be synced. In GP6, it will write the same data to wal to use streaming replication, the data will be appended to the AOCS file and wal at the same time.
4.  Update the length of L0File.

# Read

1.  Get the SuperVersion from TableMetaCache, Superversion will be loaded from disk if necessary.
2.  Get length of all L0Files. All data written by transactions that not in the current snapshot have been in L0File. We may not be able to read the data written by the running transaction, but that's OK, The data should not be visible to us.
3.  Scan

# Compaction

It is like something composed of Vacuum in PostgreSQL and Compaction in RocksDB. Use [global_xmin()](https://github.com/KuiBaDB/KuiBaDB/blob/master/src/access/xact.rs) to do the vacuum.

# Delete

The input of delete operation is FileId + RowId. Delete operation use this to update corresponding xmax in mvcc file. Delete and Compaction cannot be performed at the same time. Imagine that we are deleting file0.row1 when we are doing the following compaction.

```
 file0                                             file1
+------+                                          +------+
| row1 |                                          | row1 |
+------+                                          +------+
| row2 |       compaction position for file1 ---->| row2 |
+------+                                          +------+
| row3 |<---- compaction position for file0       | row3 |
+------+                                          +------+
| row4 |
+------+                    |
                            |
                            |
                           \|/
                     +------------+
                     | file0.row1 |
                     +------------+
                     | file1.row1 |
                     +------------+
                     | file0.row2 |
                     +------------+
                     |   ......   |
                     +------------+
                         file3
```

Then xmax for row1 in file0 will be updated, but xmax for file0.row1 in the new file, file3, still is 0. It means that the deletion is ignored by compaction.

# Update

Update is implemented by Delete + Insert, If a row to be updated has been deleted by another transaction, we will report an error: "tuple concurrently updated/deleted". We only support RR isolation level.

# Freeze

We will save the commit status of xmin/xmax in infomask so that clog can be truncated to reduce the size of clog.

# secondary index

~~ Do we really need index in OLAP? ~~

Each data file in L2 may have some secondary indexes to speed up some queries. We will build the secondary index when we do the Compaction. Data files in L0/L1 have no secondary index to avoid real-time index building which may decrease write throughput.

# Checkpoint

to be continued.
