// Written in the D programming language
/++
Simple SQLite interface.

This module provides a simple "object-oriented" interface to the SQLite
database engine.

Objects in this interface (Database and Query) automatically create the SQLite
objects they need. They are reference-counted, so that when their last
reference goes out of scope, the underlying SQLite objects are automatically
closed and finalized. They are not thread-safe.

Usage:
$(OL
    $(LI Create a Database object, providing the path of the database file (or
    an empty path, or the reserved path ":memory:").)
    $(LI Execute SQL code according to your need:
    $(UL
        $(LI If you don't need parameter binding, create a Query object with a
        single SQL statement and either use Query.execute() if you don't expect
        the query to return rows, or use Query.rows() directly in the other
        case.)
        $(LI If you need parameter binding, create a Query object with a
        single SQL statement that includes binding names, and use Parameter methods
        as many times as necessary to bind all values. Then either use
        Query.execute() if you don't expect the query to return rows, or use
        Query.rows() directly in the other case.)
        $(LI If you don't need parameter bindings and if you can ignore the
        rows that the query could return, you can use the facility function
        Database.execute(). In this case, more than one statements can be run
        in one call, as long as they are separated by semi-colons.)
    ))
)
See example in the documentation for the Database struct below.

The C API is available through $(D etc.c.sqlite3).

Copyright:
    Copyright Nicolas Sicard, 2011-2014.

License:
    $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).

Authors:
    Nicolas Sicard (dransic@gmail.com).

Macros:
    D = <tt>$0</tt>
    DK = <strong><tt>$0</tt></strong>
+/
module d2sqlite3;

import std.array;
import std.conv;
import std.exception;
import std.range;
import std.string;
import std.traits;
import std.typecons;
import std.variant;
public import etc.c.sqlite3;

/++
Metadata from the SQLite library.
+/
struct Sqlite3
{
    /++
    Gets the library's version string (e.g. 3.6.12).
    +/
    static @property string versionString()
    {
        return to!string(sqlite3_libversion());
    }
    
    /++
    Gets the library's version number (e.g. 3006012).
    +/
    static @property int versionNumber()
    {
        return sqlite3_libversion_number();
    }
}

deprecated enum SharedCache : bool
{
    enabled = true, /// Shared cache is _enabled.
    disabled = false /// Shared cache is _disabled (the default in SQLite).
}

/++
An interface to a SQLite database connection.
+/
struct Database
{
private:
    struct _Core
    {
        sqlite3* handle;
        
        this(sqlite3* handle)
        {
            this.handle = handle;
        }
        
        ~this()
        {
            if (handle)
            {
                auto result = sqlite3_close(handle);
                enforce(result == SQLITE_OK, new SqliteException(result));
            }
            handle = null;
        }

        @disable this(this);
        void opAssign(_Core) { assert(false); }
    }
    
    alias RefCounted!_Core Core;
    Core core;

public:
    /++
    Opens a database connection.

    The database is open using the sqlite3_open_v2 function.
    See $(LINK http://www.sqlite.org/c3ref/open.html) to know how to use the flags
    parameter or to use path as a file URI if the current configuration allows it.
    +/
    this(string path, int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    {
        sqlite3* hdl;
        auto result = sqlite3_open_v2(cast(char*) path.toStringz, &hdl, flags, null);
        core = Core(hdl);
        enforce(result == SQLITE_OK && core.handle, new SqliteException(errorMsg, result));
    }

    deprecated("Use the other constructor and set the flags to use shared cache")
    this(string path, SharedCache sharedCache)
    {
        if (sharedCache)
        {
            auto result = sqlite3_enable_shared_cache(1);
            enforce(result == SQLITE_OK, new SqliteException(errorMsg, result));
        }
        sqlite3* hdl;
        auto result = sqlite3_open(cast(char*) path.toStringz(), &hdl);
        core = Core(hdl);
        enforce(result == SQLITE_OK && core.handle, new SqliteException(errorMsg, result));
    }

    /++
    Gets the SQLite internal _handle of the database connection.
    +/
    @property sqlite3* handle()
    {
        return core.handle;
    }
    
    /++
    Explicitly closes the database.

    Throws an SqliteException if the database cannot be closed.

    After this function has been called successfully, using this databse object
    or a query depending on it is a programming error.
    +/
    void close()
    {
        auto result = sqlite3_close(handle);
        enforce(result == SQLITE_OK, new SqliteException(result));
        core.handle = null;
    }

    /++
    Execute the given SQL code.

    Rows returned by any statements are ignored.
    +/
    void execute(string sql)
    {
        char* errmsg;
        assert(core.handle);
        sqlite3_exec(core.handle, cast(char*) sql.toStringz(), null, null, &errmsg);
        if (errmsg !is null)
        {
            auto msg = to!string(errmsg);
            sqlite3_free(errmsg);
            throw new SqliteException(msg, sql);
        }
    }
    
    /++
    Creates a _query on the database and returns it.
    +/
    Query query(string sql)
    {
        return Query(this, sql);
    }
    
    /++
    Gets the number of database rows that were changed, inserted or deleted by
    the most recently completed query.
    +/
    @property int changes()
    {
        assert(core.handle);
        return sqlite3_changes(core.handle);
    }

    /++
    Gets the number of database rows that were changed, inserted or deleted
    since the database was opened.
    +/
    @property int totalChanges()
    {
        assert(core.handle);
        return sqlite3_total_changes(core.handle);
    }

    /++
    Gets the SQLite error code of the last operation.
    +/
    @property int errorCode()
    {
        return core.handle ? sqlite3_errcode(core.handle) : 0;
    }
    
    /++
    Gets the SQLite error message of the last operation.
    +/
    @property string errorMsg()
    {
        return core.handle ? sqlite3_errmsg(core.handle).to!string : "Database is not open";
    }

    /+
    Helper function to translate the arguments values of a D function
    into Sqlite values.
    +/
    private static @property string block_read_values(size_t n, string name, PT...)()
    {
        static if (n == 0)
            return null;
        else
        {
            enum index = n - 1;
            alias Unqual!(PT[index]) UT;
            static if (isBoolean!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_numeric_type(argv[@{index}]);
                    enforce(type == SQLITE_INTEGER, new SqliteException(
                        "argument @{n} of function @{name}() should be a boolean"));
                    args[@{index}] = sqlite3_value_int64(argv[@{index}]) != 0;
                };
            else static if (isIntegral!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_numeric_type(argv[@{index}]);
                    enforce(type == SQLITE_INTEGER, new SqliteException(
                        "argument @{n} of function @{name}() should be of an integral type"));
                    args[@{index}] = to!(PT[@{index}])(sqlite3_value_int64(argv[@{index}]));
                };
            else static if (isFloatingPoint!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_numeric_type(argv[@{index}]);
                    enforce(type == SQLITE_FLOAT, new SqliteException(
                        "argument @{n} of function @{name}() should be a floating point"));
                    args[@{index}] = to!(PT[@{index}])(sqlite3_value_double(argv[@{index}]));
                };
            else static if (isSomeString!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_type(argv[@{index}]);
                    enforce(type == SQLITE3_TEXT, new SqliteException(
                        "argument @{n} of function @{name}() should be a string"));
                    args[@{index}] = to!(PT[@{index}])(sqlite3_value_text(argv[@{index}]));
                };
            else static if (isArray!UT && is(Unqual!(ElementType!UT) : ubyte))
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_type(argv[@{index}]);
                    enforce(type == SQLITE_BLOB, new SqliteException(
                        "argument @{n} of function @{name}() should be of an array of bytes (BLOB)"));
                    n = sqlite3_value_bytes(argv[@{index}]);
                    blob.length = n;
                    import std.c.string : memcpy;
                    memcpy(blob.ptr, sqlite3_value_blob(argv[@{index}]), n);
                    args[@{index}] = to!(PT[@{index}])(blob.dup);
                };
            else
                static assert(false, PT[index].stringof ~ " is not a compatible argument type");

            return render(templ, [
                "previous_block": block_read_values!(n - 1, name, PT),
                "index":  to!string(index),
                "n": to!string(n),
                "name": name
            ]);
        }
    }

    /+
    Helper function to translate the return of a function into a Sqlite value.
    +/
    private static @property string block_return_result(RT...)()
    {
        static if (isIntegral!RT || isBoolean!RT)
            return q{
                auto result = to!long(tmp);
                sqlite3_result_int64(context, result);
            };
        else static if (isFloatingPoint!RT)
            return q{
                auto result = to!double(tmp);
                sqlite3_result_double(context, result);
            };
        else static if (isSomeString!RT)
            return q{
                auto result = to!string(tmp);
                if (result)
                    sqlite3_result_text(context, cast(char*) result.toStringz(), -1, null);
                else
                    sqlite3_result_null(context);
            };
        else static if (isArray!RT && is(Unqual!(ElementType!RT) == ubyte))
            return q{
                auto result = to!(ubyte[])(tmp);
                if (result)
                    sqlite3_result_blob(context, cast(void*) result.ptr, cast(int) result.length, null);
                else
                    sqlite3_result_null(context);
            };
        else
            static assert(false, RT.stringof ~ " is not a compatible return type");
    }

    /++
    Creates and registers a new aggregate function in the database.

    The type Aggregate must be a $(DK struct) that implements at least these
    two methods: $(D accumulate) and $(D result), and that must be default-constructible.

    See also: $(LINK http://www.sqlite.org/lang_aggfunc.html)
    +/
    void createAggregate(Aggregate, string name = Aggregate.stringof)()
    {
        import std.typetuple;

        static assert(is(Aggregate == struct), name ~ " shoud be a struct");
        static assert(is(typeof(Aggregate.accumulate) == function), name ~ " shoud define accumulate()");
        static assert(is(typeof(Aggregate.result) == function), name ~ " shoud define result()");

        alias staticMap!(Unqual, ParameterTypeTuple!(Aggregate.accumulate)) PT;
        alias ReturnType!(Aggregate.result) RT;

        enum x_step = q{
            extern(C) static void @{name}_step(sqlite3_context* context, int argc, sqlite3_value** argv)
            {
                Aggregate* agg = cast(Aggregate*) sqlite3_aggregate_context(context, Aggregate.sizeof);
                if (!agg)
                {
                    sqlite3_result_error_nomem(context);
                    return;
                }

                PT args;
                int type;
                @{blob}

                @{block_read_values}

                try
                {
                    agg.accumulate(args);
                }
                catch (Exception e)
                {
                    auto txt = "error in aggregate function @{name}(): " ~ e.msg;
                    sqlite3_result_error(context, cast(char*) txt.toStringz(), -1);
                }
            }
        };
        enum x_step_mix = render(x_step, [
            "name": name,
            "blob": staticIndexOf!(ubyte[], PT) >= 0 ? q{ubyte[] blob;} : "",
            "block_read_values": block_read_values!(PT.length, name, PT)
        ]);

        mixin(x_step_mix);

        enum x_final = q{
            extern(C) static void @{name}_final(sqlite3_context* context)
            {
                Aggregate* agg = cast(Aggregate*) sqlite3_aggregate_context(context, Aggregate.sizeof);
                if (!agg)
                {
                    sqlite3_result_error_nomem(context);
                    return;
                }

                try
                {
                    auto tmp = agg.result();
                    mixin(block_return_result!RT);
                }
                catch (Exception e)
                {
                    auto txt = "error in aggregate function @{name}(): " ~ e.msg;
                    sqlite3_result_error(context, cast(char*) txt.toStringz(), -1);
                }
            }
        };
        enum x_final_mix = render(x_final, [
            "name": name
        ]);

        mixin(x_final_mix);

        assert(core.handle);
        auto result = sqlite3_create_function(
            core.handle,
            name.toStringz(),
            PT.length,
            SQLITE_UTF8,
            null,
            null,
            mixin(format("&%s_step", name)),
            mixin(format("&%s_final", name))
        );
        enforce(result == SQLITE_OK, new SqliteException(errorMsg, result));
    }
    ///
    unittest // Aggregate creation
    {
        struct weighted_average
        {
            double total_value = 0.0;
            double total_weight = 0.0;

            void accumulate(double value, double weight)
            {
                total_value += value * weight;
                total_weight += weight;
            }

            double result()
            {
                return total_value / total_weight;
            }
        }

        auto db = Database(":memory:");
        db.execute("CREATE TABLE test (value FLOAT, weight FLOAT)");
        db.createAggregate!(weighted_average, "w_avg")();

        auto query = db.query("INSERT INTO test (value, weight) VALUES (:v, :w)");
        double[double] list = [11.5: 3, 14.8: 1.6, 19: 2.4];
        foreach (value, weight; list) {
            query.bind(":v", value);
            query.bind(":w", weight);
            query.execute();
            query.reset();
        }

        query = db.query("SELECT w_avg(value, weight) FROM test");
        import std.math: approxEqual;        
        assert(approxEqual(query.oneValue!double, (11.5*3 + 14.8*1.6 + 19*2.4)/(3 + 1.6 + 2.4)));
    }

    /++
    Creates and registers a collation function in the database.

    The function $(D_PARAM fun) must satisfy these criteria:
    $(UL
        $(LI It must take two string arguments, e.g. s1 and s2.)
        $(LI Its return value $(D ret) must satisfy these criteria (when s3 is any other string):
            $(UL
                $(LI If s1 is less than s2, $(D ret < 0).)
                $(LI If s1 is equal to s2, $(D ret == 0).)
                $(LI If s1 is greater than s2, $(D ret > 0).)
                $(LI If s1 is equal to s2, then s2 is equal to s1.)
                $(LI If s1 is equal to s2 and s2 is equal to s3, then s1 is equal to s3.)
                $(LI If s1 is less than s2, then s2 is greater than s1.)
                $(LI If s1 is less than s2 and s2 is less than s3, then s1 is less than s3.)
            )
        )
    )
    The function will have the name $(D_PARAM name) in the database; this name defaults to
    the identifier of the function fun.

    See also: $(LINK http://www.sqlite.org/lang_aggfunc.html)
    +/
    void createCollation(alias fun, string name = __traits(identifier, fun))()
    {
        static assert(__traits(isStaticFunction, fun), "symbol " ~ __traits(identifier, fun)
                      ~ " of type " ~ typeof(fun).stringof ~ " is not a static function");

        alias ParameterTypeTuple!fun PT;
        static assert(isSomeString!(PT[0]), "the first argument of function " ~ name ~ " should be a string");
        static assert(isSomeString!(PT[1]), "the second argument of function " ~ name ~ " should be a string");
        static assert(isImplicitlyConvertible!(ReturnType!fun, int), "function " ~ name ~ " should return a value convertible to an int");

        enum x_compare = q{
            extern (C) static int @{name}(void*, int n1, const(void*) str1, int n2, const(void* )str2)
            {
                char[] s1, s2;
                s1.length = n1;
                s2.length = n2;
                import std.c.string : memcpy;
                memcpy(s1.ptr, str1, n1);
                memcpy(s2.ptr, str2, n2);
                return fun(cast(immutable) s1, cast(immutable) s2);
            }
        };
        mixin(render(x_compare, ["name": name]));

        assert(core.handle);
        auto result = sqlite3_create_collation(
            core.handle,
            name.toStringz(),
            SQLITE_UTF8,
            null,
            mixin("&" ~ name)
        );
        enforce(result == SQLITE_OK, new SqliteException(errorMsg, result));
    }
    ///
    unittest // Collation creation
    {
        static int my_collation(string s1, string s2)
        {
            import std.uni;
            return icmp(s1, s2);
        }

        auto db = Database(":memory:");
        db.createCollation!my_collation();
        db.execute("CREATE TABLE test (word TEXT)");

        auto query = db.query("INSERT INTO test (word) VALUES (:wd)");
        foreach (word; ["straße", "strasses"])
        {
            query.bind(":wd", word);
            query.execute();
            query.reset();
        }

        query = db.query("SELECT word FROM test ORDER BY word COLLATE my_collation");
        assert(query.oneValue!string == "straße");
    }

    /++
    Creates and registers a simple function in the database.

    The function $(D_PARAM fun) must satisfy these criteria:
    $(UL
        $(LI It must not be a variadic.)
        $(LI Its arguments must all have a type that is compatible with SQLite types:
             boolean, integral, floating point, string, or array of bytes (BLOB types).)
        $(LI Its return value must also be of a compatible type.)
    )
    The function will have the name $(D_PARAM name) in the database; this name defaults to
    the identifier of the function fun.

    See also: $(LINK http://www.sqlite.org/lang_corefunc.html)
    +/
    void createFunction(alias fun, string name = __traits(identifier, fun))()
    {
        import std.typetuple;

        static if (__traits(isStaticFunction, fun))
            enum funpointer = &fun;
        else
            static assert(false, "symbol " ~ __traits(identifier, fun) ~ " of type "
                          ~ typeof(fun).stringof ~ " is not a static function");

        static assert(variadicFunctionStyle!(fun) == Variadic.no);

        alias staticMap!(Unqual, ParameterTypeTuple!fun) PT;
        alias ReturnType!fun RT;

        enum x_func = q{
            extern(C) static void @{name}(sqlite3_context* context, int argc, sqlite3_value** argv)
            {
                PT args;
                int type, n;
                @{blob}

                @{block_read_values}

                try
                {
                    auto tmp = funpointer(args);
                    mixin(block_return_result!RT);
                }
                catch (Exception e)
                {
                    auto txt = "error in function @{name}(): " ~ e.msg;
                    sqlite3_result_error(context, cast(char*) txt.toStringz(), -1);
                }
            }
        };
        enum x_func_mix = render(x_func, [
            "name": name,
            "blob": staticIndexOf!(ubyte[], PT) >= 0 ? q{ubyte[] blob;} : "",
            "block_read_values": block_read_values!(PT.length, name, PT)
        ]);

        mixin(x_func_mix);

        assert(core.handle);
        auto result = sqlite3_create_function(
            core.handle,
            name.toStringz(),
            PT.length,
            SQLITE_UTF8,
            null,
            mixin(format("&%s", name)),
            null,
            null
        );
        enforce(result == SQLITE_OK, new SqliteException(errorMsg, result));
    }
    ///
    unittest // Function creation
    {
        static string my_msg(string name)
        {
            return "Hello, %s!".format(name);
        }
       
        auto db = Database(":memory:");
        db.createFunction!my_msg();

        auto query = db.query("SELECT my_msg('John')");
        assert(query.oneValue!string() == "Hello, John!");
    }
}

///
unittest // Documentation example
{
    // Open a database in memory.
    Database db;
    try
    {
        db = Database(":memory:");
    }
    catch (SqliteException e)
    {
        // Error creating the database
        assert(false, "Error: " ~ e.msg);
    }
    
    // Create a table.
    try
    {
        db.execute(
            "CREATE TABLE person (
                id INTEGER PRIMARY KEY,
                last_name TEXT NOT NULL,
                first_name TEXT,
                score REAL,
                photo BLOB
             )"
        );
    }
    catch (SqliteException e)
    {
        // Error creating the table.
        assert(false, "Error: " ~ e.msg);
    }
    
    // Populate the table.
    try
    {
        auto query = db.query(
            "INSERT INTO person (last_name, first_name, score, photo)
             VALUES (:last_name, :first_name, :score, :photo)"
        );
        
        // Bind everything with chained calls to params.bind().
        query.bind(":last_name", "Smith");
        query.bind(":first_name", "John");
        query.bind(":score", 77.5);
        ubyte[] photo = cast(ubyte[]) "..."; // Store the photo as raw array of data.
        query.bind(":photo", photo);
        query.execute();
        
        query.reset(); // Need to reset the query after execution.
        query.bind(":last_name", "Doe");
        query.bind(":first_name", "John");
        query.bind(3, null); // Use of index instead of name.
        query.bind(":photo", null);
        query.execute();
    }
    catch (SqliteException e)
    {
        // Error executing the query.
        assert(false, "Error: " ~ e.msg);
    }
    assert(db.totalChanges == 2); // Two 'persons' were inserted.
    
    // Reading the table
    try
    {
        // Count the Johns in the table.
        auto query = db.query("SELECT count(*) FROM person WHERE first_name == 'John'");
        assert(query.front[0].get!int() == 2);
        
        // Fetch the data from the table.
        query = db.query("SELECT * FROM person");
        foreach (row; query)
        {
            // "id" should be the column at index 0:
            auto id = row[0].get!int();
            // Some conversions are possible with the method as():
            auto name = format("%s, %s", row["last_name"].get!string(), row["first_name"].get!(char[])());
            // The score can be NULL, so provide 0 (instead of NAN) as a default value to replace NULLs:
            auto score = row["score"].get!real(0.0);
            // Use opDispatch to retrieve a column from its name
            auto photo = row.photo.get!(ubyte[])();
            
            // ... and use all these data!
        }
    }
    catch (SqliteException e)
    {
        // Error reading the database.
        assert(false, "Error: " ~ e.msg);
    }
}

unittest // Database construction
{
    Database db1;
    auto db2 = db1;
    db1 = Database(":memory:");
    db2 = Database("");
    auto db3 = Database(null);
    db1 = db2;
    assert(db2.core.refCountedStore.refCount == 2);
    assert(db1.core.refCountedStore.refCount == 2);
}

unittest // Execute an SQL statement
{
    auto db = Database(":memory:");
    db.execute(";");
    db.execute("ANALYZE");
}

/++
An interface to SQLite query execution.
+/
struct Query
{
private:
    struct _Core
    {
        Database db;
        string sql;
        sqlite3_stmt* statement; // null if error or empty statement
        int state;
        
        this(Database db, string sql, sqlite3_stmt* statement)
        {
            this.db = db;
            this.sql = sql;
            this.statement = statement;
        }
        
        ~this()
        {
            auto result = sqlite3_finalize(statement);
            enforce(result == SQLITE_OK, new SqliteException(result));
            statement = null;
        }

        @disable this(this);
        void opAssign(_Core) { assert(false); }
    }
    alias RefCounted!_Core Core;
    Core core;
    
    @disable this();
    
    this(Database db, string sql)
    {
        sqlite3_stmt* statement;
        auto result = sqlite3_prepare_v2(
            db.core.handle,
            cast(char*) sql.toStringz(),
            cast(int) sql.length,
            &statement,
            null
        );
        enforce(result == SQLITE_OK, new SqliteException(db.errorMsg, result, sql));
        core = Core(db, sql, statement);
        if (statement is null)
            core.state = SQLITE_DONE;
    }

    int parameterCount()
    {
        if (core.statement)
            return sqlite3_bind_parameter_count(core.statement);
        else
            return 0;
    }

public:
    /++
    Gets the SQLite internal handle of the query _statement.
    +/
    @property sqlite3_stmt* statement()
    {
        return core.statement;
    }
    
    /++
    Binds values to parameters in the query.

    The index is the position of the parameter in the SQL query (starting from 0).
    The name must include the ':', '@' or '$' that introduces it in the query.
    +/
    void bind(T)(int index, T value)
    {
        enforce(parameterCount > 0, new SqliteException("no parameter to bind to"));
        
        alias Unqual!T U;
        int result;
        
        static if (is(U == typeof(null)))
            result = sqlite3_bind_null(core.statement, index);
        else static if (is(U == void*))
            result = sqlite3_bind_null(core.statement, index);
        else static if (isIntegral!U && U.sizeof == int.sizeof)
            result = sqlite3_bind_int(core.statement, index, value);
        else static if (isIntegral!U && U.sizeof == long.sizeof)
            result = sqlite3_bind_int64(core.statement, index, cast(long) value);
        else static if (isImplicitlyConvertible!(U, double))
            result = sqlite3_bind_double(core.statement, index, value);
        else static if (isSomeString!U)
        {
            import std.utf : toUTF8;
            string utf8 = value.toUTF8();
            enforce(utf8.length <= int.max, new SqliteException("string too long"));
            result = sqlite3_bind_text(core.statement, index, cast(char*) utf8.toStringz(), cast(int) utf8.length, null);
        }
        else static if (isArray!U)
        {
            if (!value.length)
                result = sqlite3_bind_null(core.statement, index);
            else
            {
                auto bytes = cast(ubyte[]) value;
                enforce(bytes.length <= int.max, new SqliteException("array too long"));
                result = sqlite3_bind_blob(core.statement, index, cast(void*) bytes.ptr, cast(int) bytes.length, null);
            }
        }
        else
            static assert(false, "cannot bind a value of type " ~ U.stringof);
        
        enforce(result == SQLITE_OK, new SqliteException(result));
    }

    /// Ditto
    void bind(T)(string name, T value)
    {
        enforce(parameterCount > 0, new SqliteException("no parameter to bind to"));
        auto index = sqlite3_bind_parameter_index(core.statement, cast(char*) name.toStringz());
        enforce(index > 0, new SqliteException(format("no parameter named '%s'", name)));
        bind(index, value);
    }

    /++
    Clears the bindings.

    This does not reset the prepared statement. Use Query.reset() for this.
    +/
    void clearBindings()
    {
        if (core.statement)
        {
            auto result = sqlite3_clear_bindings(core.statement);
            enforce(result == SQLITE_OK, new SqliteException(result));
        }
    }

    /++
    Resets a query's prepared statement before a new execution.

    This does not clear the bindings. Use Query.clear() for this.
    +/
    void reset()
    {
        if (core.statement)
        {
            auto result = sqlite3_reset(core.statement);
            enforce(result == SQLITE_OK, new SqliteException(core.db.errorMsg, result));
            core.state = 0;
        }
    }
    
    /++
    Executes the query.

    If the query is expected to return rows, use the query's input range interface
    to iterate over them.
    +/
    void execute()
    {
        core.state = sqlite3_step(core.statement);
        if (core.state != SQLITE_ROW && core.state != SQLITE_DONE)
        {
            reset(); // necessary to retrieve the error message.
            throw new SqliteException(core.db.errorMsg, core.state);
        }
    }
    
    /++
    InputRange interface. A $(D Query) is an input range of $(D Row)s.
    +/
    @property bool empty()
    {
        return core.state == SQLITE_DONE;
    }
    
    /// ditto
    @property Row front()
    {
        if (!core.state) execute();
        assert(core.state);
        enforce(!empty, new SqliteException("No rows available"));
        return Row(core.statement);
    }
    
    /// ditto
    void popFront()
    {
        if (!core.state) execute();
        assert(core.state);
        enforce(!empty, new SqliteException("No rows available"));
        core.state = sqlite3_step(core.statement);
        enforce(core.state == SQLITE_DONE || core.state == SQLITE_ROW,
               new SqliteException(core.db.errorMsg, core.state));
    }

    /++
    Gets only the first value of the first row returned by a query.
    +/
    auto oneValue(T)()
    {
        return front.front.get!T();
    }
    ///
    unittest // One value
    {
        auto db = Database(":memory:");
        db.execute("CREATE TABLE test (val INTEGER)");
        auto query = db.query("SELECT count(*) FROM test");
        assert(query.oneValue!int == 0);
    }
    
    /++
    Gets the results of a query as a 2D array.

    Warning:
        Calling this function resets the query: don't call it while
        iterating the rows with the input range interface.
    +/
    Column[][] array()
    {
        static Column[][] result;
        if (!result)
        {
            auto rowapp = appender!(Column[][]);
            foreach (row; this)
            {
                auto colapp = appender!(Column[]);
                foreach (col; row)
                    colapp.put(col);
                rowapp.put(colapp.data);
            }
            result = rowapp.data;
            reset();
        }
        return result;
    }
}

unittest // Empty query
{
    auto db = Database(":memory:");
    db.execute(";");
    auto query = db.query("-- This is a comment !");
    assert(query.empty);
    assert(query.parameterCount == 0);
    query.clearBindings();
    query.reset();
}

unittest // Simple parameters binding
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val INTEGER)");
    
    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.bind(":val", 42);
    query.execute();
    query.reset();
    query.bind(1, 42);
    query.execute();
    
    query = db.query("SELECT * FROM test");
    foreach (row; query)
        assert(row[0].get!int() == 42);
}

unittest // Multiple parameters binding
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (i INTEGER, f FLOAT, t TEXT)");
    auto query = db.query("INSERT INTO test (i, f, t) VALUES (:i, @f, $t)");
    assert(query.parameterCount == 3);
    query.bind("$t", "TEXT");
    query.bind(":i", 42);
    query.bind("@f", 3.14);
    query.execute();
    query.reset();
    query.bind(3, "TEXT");
    query.bind(1, 42);
    query.bind(2, 3.14);
    query.execute();
    
    query = db.query("SELECT * FROM test");
    foreach (row; query)
    {
        assert(row.length == 3);
        assert(row["i"].get!int() == 42);
        assert(row["f"].get!double() == 3.14);
        assert(row["t"].get!string() == "TEXT");
    }
}

unittest // Query references
{
    auto db = Database(":memory:");
    {
        db.execute("CREATE TABLE test (val INTEGER)");
        auto tmp = db.query("INSERT INTO test (val) VALUES (:val)");
        tmp.bind(":val", 42);
        tmp.execute();
    }
    
    auto query = { return db.query("SELECT * FROM test"); }();
    assert(!query.empty);
    assert(query.front[0].get!int() == 42);
    query.popFront();
    assert(query.empty);
}


/++
A SQLite row, implemented as a random-access range of $(D Column) objects.

Warning:
    A Row is just a view of the current row when iterating the results of a $(D Query). 
    It becomes invalid as soon as $(D Query.popFront) is called. Row contains
    undefined data afterwards.
+/
struct Row
{
    private
    {
        sqlite3_stmt* statement;
        int frontIndex;
        int backIndex;
    }

    this(sqlite3_stmt* statement)
    {
        assert(statement);
        this.statement = statement;
        backIndex = sqlite3_column_count(statement) - 1;
    }

    /// Input range primitives.
    @property bool empty()
    {
        return length == 0;
    }

    /// ditto
    @property Column front()
    {
        return opIndex(0);
    }

    /// ditto
    void popFront()
    {
        frontIndex++;
    }
   
    /// Forward range primitive.
    @property Row save()
    {
        Row ret;
        ret.statement = statement;
        ret.frontIndex = frontIndex;
        ret.backIndex = backIndex;
        return ret;
    }
    
    /// Bidirectional range primitives.
    @property Column back()
    {
        return opIndex(backIndex - frontIndex);
    }
    
    /// ditto
    void popBack()
    {
        backIndex--;
    }
    
    /// Random access range primitives.
    @property size_t length()
    {
        return backIndex - frontIndex + 1;
    }
    
    /// ditto
    Column opIndex(size_t index)
    {
        enforce(index < int.max, new SqliteException(format("index too high: %d", index)));
        int i =  cast(int) index + frontIndex;

        enforce(i >= 0 && i <= backIndex,
                new SqliteException(format("invalid column index: %d", i)));
                
        auto type = sqlite3_column_type(statement, i);
        final switch (type) {
            case SQLITE_INTEGER:
                return Column(Variant(sqlite3_column_int64(statement, i)), type);

            case SQLITE_FLOAT:
                return Column(Variant(sqlite3_column_double(statement, i)), type);

            case SQLITE3_TEXT:
                return Column(Variant(sqlite3_column_text(statement, i).to!string), type);

            case SQLITE_BLOB:
                auto ptr = sqlite3_column_blob(statement, i);
                auto length = sqlite3_column_bytes(statement, i);
                ubyte[] blob;
                blob.length = length;
                import std.c.string : memcpy;
                memcpy(blob.ptr, ptr, length);
                return Column(Variant(blob), type);

            case SQLITE_NULL:
                return Column(Variant.init, type);        
        }
    }

    /++
    Returns a column based on its name.

    The names of the statements' columns are checked each time this function is called:
    use numeric indexing for better performance.
    +/
    Column opIndex(string name)
    {
        foreach (i; frontIndex .. backIndex + 1)
            if (sqlite3_column_name(statement, i).to!string == name)
                return opIndex(i);

        throw new SqliteException("invalid column name: '%s'".format(name));
    }

    /// ditto
    @property Column opDispatch(string name)()
    {
        return opIndex(name);
    }
}

version (unittest)
{
    static assert(isRandomAccessRange!Row);
    static assert(is(ElementType!Row == Column));
}

unittest // Row random-access range interface
{
    auto db = Database(":memory:");

    {
        db.execute("CREATE TABLE test (a INTEGER, b INTEGER, c INTEGER, d INTEGER)");
        auto query = db.query("INSERT INTO test (a, b, c, d) VALUES (:a, :b, :c, :d)");
        query.bind(":a", 1);
        query.bind(":b", 2);
        query.bind(":c", 3);
        query.bind(":d", 4);
        query.execute();
        query.reset();
        query.bind(":a", 5);
        query.bind(":b", 6);
        query.bind(":c", 7);
        query.bind(":d", 8);
        query.execute();
    }

    {
        auto query = db.query("SELECT * FROM test");
        auto values = [1, 2, 3, 4, 5, 6, 7, 8];
        foreach (row; query)
        {
            while (!row.empty)
            {
                assert(row.front.get!int == values.front);
                row.popFront();
                values.popFront();
            }
        }
    }

    {
        auto query = db.query("SELECT * FROM test");
        auto values = [4, 3, 2, 1, 8, 7, 6, 5];
        foreach (row; query)
        {
            while (!row.empty)
            {
                assert(row.back.get!int == values.front);
                row.popBack();
                values.popFront();
            }
        }
    }

    auto query = { return db.query("SELECT * FROM test"); }();
    auto values = [1, 2, 3, 4, 5, 6, 7, 8];
    foreach (row; query)
    {
        while (!row.empty)
        {
            assert(row.front.get!int == values.front);
            row.popFront();
            values.popFront();
        }
    }
}


/++
A SQLite column.
+/
struct Column
{
    private {
        Variant data;
        int _type;
    }

    /++
    Gets the value of the column converted _to type T.
    If the value is NULL, it is replaced by defaultValue.

    T can be a boolean, a numeric type, a string, an array or a Variant.
    +/
    T get(T)(T defaultValue = T.init)
    {
        alias Unqual!T U;
        if (data.hasValue)
        {
            static if (is(U == bool))
                return cast(T) data.coerce!long() != 0;
            else static if (isIntegral!U)
                return cast(T) std.conv.to!U(data.coerce!long());
            else static if (isFloatingPoint!U)
                return cast(T) std.conv.to!U(data.coerce!double());
            else static if (isSomeString!U)
            {
                auto result = cast(T) std.conv.to!U(data.coerce!string());
                return result ? result : defaultValue;
            }
            else static if (isArray!U)
            {
                alias A = ElementType!U;
                auto result = cast(U) data.get!(ubyte[]);
                return result ? result : defaultValue;
            }
            else static if (is(T == Variant))
                return data;
            else
                static assert(false, "value cannot be converted to type " ~ T.stringof);
        }
        else
            return defaultValue;
    }

    /++
    Gets the type of the column.
    +/
    @property int type()
    {
        return _type;
    }
}

unittest // Getting a column
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val INTEGER)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.bind(":val", 42);
    query.execute();

    query = db.query("SELECT val FROM test");
    with (query)
    {
        assert(front[0].get!int() == 42);
        assert(front["val"].get!int() == 42);
        assert(front.val.get!int() == 42);

        auto v = front[0].get!Variant();
        assert(v.coerce!int == 42);
        assert(v.coerce!string == "42");
    }
}

unittest // Getting null values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val INTEGER)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.bind(":val", null);
    query.execute();

    query = db.query("SELECT * FROM test");
    assert(query.front["val"].get!int(-42) == -42);
}

unittest // Getting integer values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val INTEGER)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.bind(":val", 2);
    query.clearBindings(); // Resets binding to NULL.
    query.execute();
    query.reset();
    query.bind(":val", 42L);
    query.execute();
    query.reset();
    query.bind(":val", 42U);
    query.execute();
    query.reset();
    query.bind(":val", 42UL);
    query.execute();
    query.reset();
    query.bind(":val", true);
    query.execute();
    query.reset();
    query.bind(":val", '\x2A');
    query.execute();
    query.reset();
    query.bind(":val", null);
    query.execute();

    query = db.query("SELECT * FROM test");
    foreach (row; query)
        assert(row[0].get!long(42) == 42 || row[0].get!long() == 1);
}

unittest // Getting float values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val FLOAT)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.bind(":val", 42.0F);
    query.execute();
    query.reset();
    query.bind(":val", 42.0);
    query.execute();
    query.reset();
    query.bind(":val", 42.0L);
    query.execute();
    query.reset();
    query.bind(":val", null);
    query.execute();

    query = db.query("SELECT * FROM test");
    foreach (row; query)
        assert(row[0].get!real(42.0) == 42.0);
}

unittest // Getting text values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val TEXT)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.bind(":val", "I am a text.");
    query.execute();
    query.reset();
    query.bind(":val", null);
    query.execute();
    string str;
    query.reset();
    query.bind(":val", str);
    query.execute();

    query = db.query("SELECT * FROM test");
    assert(query.front[0].get!string("I am a text") == "I am a text.");
}

unittest // Getting blob values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val BLOB)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    ubyte[] array = [1, 2, 3];
    query.bind(":val", array);
    query.execute();
    query.reset();
    query.bind(":val", cast(ubyte[]) []);
    query.execute();

    query = db.query("SELECT * FROM test");
    foreach (row; query)
        assert(row[0].get!(ubyte[])([1, 2, 3]) ==  [1, 2, 3]);
}

unittest // Getting more blob values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val BLOB)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    double[] array = [1.1, 2.14, 3.162];
    query.bind(":val", array);
    query.execute();
    query.reset();
    query.bind(":val", cast(double[]) []);
    query.execute();

    query = db.query("SELECT * FROM test");
    foreach (row; query)
        assert(row[0].get!(double[])([1.1, 2.14, 3.162]) ==  [1.1, 2.14, 3.162]);
}

/++
Turns a value into a literal that can be used in an SQLite expression.
+/
string literal(T)(T value)
{
    static if (is(T == typeof(null)))
        return "NULL";
    else static if (isBoolean!T)
        return value ? "1" : "0";
    else static if (isNumeric!T)
        return value.to!string();
    else static if (isSomeString!T)
        return format("'%s'", value.replace("'", "''"));
    else static if (isArray!T)
        return "'X%(%X%)'".format(cast(ubyte[]) value);
    else
        static assert(false, "cannot make a literal of a value of type " ~ T.stringof);
}
///
unittest
{
    assert(null.literal == "NULL");
    assert(false.literal == "0");
    assert(true.literal == "1");
    assert(4.literal == "4");
    assert(4.1.literal == "4.1");
    assert("foo".literal == "'foo'");
    assert("a'b'".literal == "'a''b'''");
    auto a = cast(ubyte[]) x"DEADBEEF";
    assert(a.literal == "'XDEADBEEF'");
}

/++
Exception thrown when SQLite functions return an error.
+/
class SqliteException : Exception
{
    int code;
    string sql;

    private this(string msg, string sql, int code,
                 string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this.sql = sql;
        this.code = code;
        super(msg, file, line, next);
    }

    this(int code, string sql = null,
         string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this("error %d".format(code), sql, code, file, line, next);
    }

    this(string msg, int code, string sql = null,
         string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this("error %d : %s".format(code, msg), sql, code, file, line, next);
    }

    this(string msg, string sql = null,
         string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this(msg, sql, code, file, line, next);
    }
}

// Compile-time rendering of code templates.
private string render(string templ, string[string] args)
{
    string markupStart = "@{";
    string markupEnd = "}";

    string result;
    auto str = templ;
    while (true)
    {
        auto p_start = std.string.indexOf(str, markupStart);
        if (p_start < 0)
        {
            result ~= str;
            break;
        }
        else
        {
            result ~= str[0 .. p_start];
            str = str[p_start + markupStart.length .. $];

            auto p_end = std.string.indexOf(str, markupEnd);
            if (p_end < 0)
                assert(false, "Tag misses ending }");
            auto key = strip(str[0 .. p_end]);

            auto value = key in args;
            if (!value)
                assert(false, "Key '" ~ key ~ "' has no associated value");
            result ~= *value;

            str = str[p_end + markupEnd.length .. $];
        }
    }

    return result;
}

unittest // Code templates
{
    enum tpl = q{
        string @{function_name}() {
            return "Hello world!";
        }
    };
    mixin(render(tpl, ["function_name": "hello_world"]));
    static assert(hello_world() == "Hello world!");
}
