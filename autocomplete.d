//          Copyright Brian Schott (Sir Alaran) 2012.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module autocomplete;

import std.range;
import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import std.typecons;
import std.path;
import std.file;

import parser;
import langutils;
import types;
import tokenizer;

immutable string[] versions = ["AIX", "all", "Alpha", "ARM", "BigEndian", "BSD",
	"Cygwin", "D_Coverage", "D_Ddoc", "DigitalMars", "D_InlineAsm_X86",
	"D_InlineAsm_X86_64", "D_LP64", "D_NET", "D_PIC", "D_Version2",
	"FreeBSD", "GNU", "HPPA", "HPPA64", "Hurd", "IA64", "LDC", "linux",
	"LittleEndian", "MinGW", "MIPS", "MIPS64", "none", "OpenBSD", "OSX",
	"Posix", "PPC", "PPC64", "S390", "S390X", "SDC", "SH", "SH64", "SkyOS",
	"Solaris", "SPARC", "SPARC64", "SysV3", "SysV4", "unittest", "Win32",
	"Win64", "Windows", "X86", "X86_64"
];

immutable string[] scopes = ["exit", "failure", "success"];

/**
 * Returns: indicies into the token array
 */
size_t findEndOfExpression(const Token[] tokens, const size_t index)
out (result)
{
	assert (result < tokens.length);
	assert (result >= index);
}
body
{
	size_t i = index;
	loop: while (i < tokens.length)
	{
		switch (tokens[i].type)
		{
		case TokenType.Return:
		case TokenType.New:
		case TokenType.Delete:
		case TokenType.Comma:
		case TokenType.RBrace:
		case TokenType.RParen:
		case TokenType.RBracket:
		case TokenType.Semicolon:
			break loop;
		case TokenType.LParen:
			skipParens(tokens, i);
			break;
		case TokenType.LBrace:
			skipBraces(tokens, i);
			break;
		case TokenType.LBracket:
			skipBrackets(tokens, i);
			break;
		default:
			++i;
			break;
		}
	}
	return i;
}

size_t findBeginningOfExpression(const Token[] tokens, const size_t index)
in
{
	assert (index < tokens.length);
	assert (tokens.length > 0);
}
out (result)
{
	import std.string;
	assert (result < tokens.length);
	assert (result <= index, format("%d, %d", result, index));
}
body
{
	size_t i = index;
	loop: while (i < tokens.length)
	{
		switch (tokens[i].type)
		{
		case TokenType.Assign: case TokenType.BitAnd: case TokenType.BitAndEquals:
		case TokenType.BitOr: case TokenType.BitOrEquals: case TokenType.CatEquals:
		case TokenType.Colon: case TokenType.Comma: case TokenType.Decrement:
		case TokenType.Div: case TokenType.DivEquals: case TokenType.Dollar:
		case TokenType.Dot: case TokenType.Equals: case TokenType.GoesTo:
		case TokenType.Greater: case TokenType.GreaterEqual: case TokenType.Hash:
		case TokenType.Increment: case TokenType.LBrace: case TokenType.LBracket:
		case TokenType.Less: case TokenType.LessEqual: case TokenType.LessEqualGreater:
		case TokenType.LessOrGreater: case TokenType.LogicAnd: case TokenType.LogicOr:
		case TokenType.LParen: case TokenType.Minus: case TokenType.MinusEquals:
		case TokenType.Mod: case TokenType.ModEquals: case TokenType.MulEquals:
		case TokenType.Not: case TokenType.NotEquals: case TokenType.NotGreater:
		case TokenType.NotGreaterEqual: case TokenType.NotLess: case TokenType.NotLessEqual:
		case TokenType.NotLessEqualGreater: case TokenType.Plus: case TokenType.PlusEquals:
		case TokenType.Pow: case TokenType.PowEquals: case TokenType.RBrace:
		case TokenType.Semicolon: case TokenType.ShiftLeft: case TokenType.ShiftLeftEqual:
		case TokenType.ShiftRight: case TokenType.ShiftRightEqual: case TokenType.Slice:
		case TokenType.Star: case TokenType.Ternary: case TokenType.Tilde:
		case TokenType.Unordered: case TokenType.UnsignedShiftRight: case TokenType.UnsignedShiftRightEqual:
		case TokenType.Vararg: case TokenType.Xor: case TokenType.XorEquals:
		case TokenType.KEYWORDS_BEGIN: .. case TokenType.KEYWORDS_END:
			return i + 1;
		case TokenType.RParen:
			if (i == 0)
				break loop;
			skipParens(tokens, i);
			break;
		case TokenType.RBracket:
			if (i == 0)
				break loop;
			skipBrackets(tokens, i);
			break;
		default:
			if (i == 0)
				break loop;
			i--;
			break;
		}
	}
	return i + 1;
}

const(Token)[] splitCallChain(const(Token)[] tokens)
{
	auto app = appender!(Token[])();
	size_t i = 0;
	while (i < tokens.length)
	{
		app.put(tokens[i++]);
		while (i < tokens.length && tokens[i] == TokenType.LParen) skipParens(tokens, i);
		while (i < tokens.length && tokens[i] == TokenType.LBracket) skipBrackets(tokens, i);
		while (i < tokens.length && tokens[i] == TokenType.Dot) ++i;
	}
	return app.data;
}

unittest
{
	auto code = `a.b[10].c("grcl").x`;
	auto tokens = tokenize(code);
	assert (splitCallChain(tokens) == ["a", "b", "c", "x"]);
}

struct AutoComplete
{
	this(const (Token)[] tokens, CompletionContext context)
	{
		this.tokens = tokens;
		this.context = context;
	}

	string getTypeOfExpression(const(Token)[] expression, const Token[] tokens, size_t cursor)
	{
		stderr.writeln("getting type of ", expression);
		if (expression.length == 0)
			return "void";
		auto type = typeOfVariable(expression[0], cursor);
		if (type is null)
			return "void";
		size_t index = 1;
		while (index < expression.length)
		{
			const Tuple!(string, string)[string] typeMap = context.getMembersOfType(
				type);
			const Tuple!(string, string)* memberType = expression[index].value in typeMap;
			if (memberType is null)
				return "void";
			else
				type = (*memberType)[0];
			index++;
		}
		return type;
	}

	string typeOfVariable(Token symbol, size_t cursor)
	{
		// int is of type int, double of type double, and so on
		if (symbol.value in typeProperties)
			return symbol.value;

		string tokenType = getTypeFromToken(symbol);
		if (tokenType !is null)
			return tokenType;

		if (context.getMembersOfType(symbol.value))
			return symbol.value;

		// Arbitrarily define the depth of the cursor position as zero
		// iterate backwards through the code to try to find the variable
		int depth = 0;
		auto preceedingTokens = assumeSorted(tokens).lowerBound(cursor);
		auto index = preceedingTokens.length - 1;
		while (true)
		{
			if (preceedingTokens[index] == TokenType.LBrace)
				--depth;
			else if (preceedingTokens[index] == TokenType.RBrace)
				++depth;
			else if (depth <= 0 && preceedingTokens[index].value == symbol)
			{
				// Found the symbol, now determine if it was declared here.
				auto p = preceedingTokens[index - 1];


				if ((p == TokenType.Auto || p == TokenType.Immutable
					|| p == TokenType.Const)
					&& preceedingTokens[index + 1] == TokenType.Assign)
				{
					// Try to determine the type of a variable declared as "auto"
					return getTypeOfExpression(
						tokens[index + 2 .. findEndOfExpression(tokens, index + 2)],
						tokens, cursor);
				}
				else if (p == TokenType.Identifier
					|| (p.type > TokenType.TYPES_BEGIN
					&& p.type < TokenType.TYPES_END))
				{
					// Handle simple cases like "int a;" or "Someclass instance;"
					return p.value;
				}
				else if (p == TokenType.RBracket || p == TokenType.RParen)
				{
					return combineTokens(tokens[findBeginningOfExpression(tokens, index) .. index]);
				}
			}
			if (index == 0)
				break;
			else
				--index;
		}

		// Find all struct or class bodies that we're in.
		// Check for the symbol in those class/struct/interface bodies
		// if match is found, return it
		auto structs = context.getStructsContaining(cursor);
		if (symbol == "this" && structs.length > 0)
		{
			return minCount!("a.bodyStart > b.bodyStart")(structs)[0].name;
		}

		foreach (s; structs)
		{
			auto t = s.getMemberType(symbol.value);
			if (t !is null)
				return t;
		}
		return "void";
	}

	string symbolAt(size_t cursor) const
	{
		auto r = assumeSorted(tokens).lowerBound(cursor)[$ - 1];
		if (r.value.length + r.startIndex > cursor)
			return r.value;
		else
			return null;
	}

	string parenComplete(size_t cursor)
	{
		auto index = assumeSorted(tokens).lowerBound(cursor).length - 2;
		Token t = tokens[index];
		switch (tokens[index].type)
		{
		case TokenType.Version:
			return "completions\n" ~ to!string(join(map!`a ~ " k"`(versions), "\n").array());
		case TokenType.Scope:
			return "completions\n" ~ to!string(join(map!`a ~ " k"`(scopes), "\n").array());
		case TokenType.If:
		case TokenType.Cast:
		case TokenType.While:
		case TokenType.For:
		case TokenType.Foreach:
		case TokenType.Switch:
			return "";
		default:
			size_t startIndex = findBeginningOfExpression(tokens, index);
			auto callChain = splitCallChain(tokens[startIndex .. index + 1]);
			auto expressionType = getTypeOfExpression(
				callChain[0 .. $ - 1], tokens, cursor);
			return "calltips\n" ~ to!string(context.getCallTipsFor(expressionType,
				callChain[$ - 1].value, cursor).join("\n").array());
		}
	}

	string dotComplete(size_t cursor)
	{
		stderr.writeln("dotComplete");
		auto index = assumeSorted(tokens).lowerBound(cursor).length - 1;
		Token t = tokens[index];

		// If the last character entered before the cursor isn't a dot, give up.
		// The user was probably in the middle of typing the slice or vararg
		// operators
		if (t != TokenType.Dot)
			return null;

		size_t startIndex = findBeginningOfExpression(tokens, index);
		if (startIndex - 1 < tokens.length && tokens[startIndex - 1] == TokenType.Import)
		{
			return importComplete(splitCallChain(tokens[startIndex .. index]));
		}

		auto expressionType = getTypeOfExpression(
			splitCallChain(tokens[startIndex .. index]), tokens, cursor);

		stderr.writeln("expression type is ", expressionType);

		// Complete pointers and references the same way
		if (expressionType[$ - 1] == '*')
			expressionType = expressionType[0 .. $ - 1];

		const Tuple!(string, string)[string] typeMap = context.getMembersOfType(
			expressionType);
		if (typeMap is null)
			return "";
		auto app = appender!(string[])();
		foreach (k, t; typeMap)
			app.put(k ~ " " ~ t[1]);
		return to!string(array(join(sort!("a.toLower() < b.toLower()")(app.data), "\n")));
	}

	string importComplete(const(Token)[] tokens)
	{
		stderr.writeln("importComplete");
		auto app = appender!(string[])();
		string part = to!string(map!"a.value.dup"(tokens).join("/").array());
		foreach (path; context.importDirectories)
		{
			stderr.writeln("Searching for ", path, "/", part);
			if (!exists(buildPath(path, part)))
				continue;
			stderr.writeln("found it");
			foreach (DirEntry dirEntry; dirEntries(buildPath(path, part),
				SpanMode.shallow))
			{
				if (dirEntry.isDir)
					app.put(baseName(dirEntry.name) ~ " P");
				else if (dirEntry.name.endsWith(".d", ".di"))
					app.put(stripExtension(baseName(dirEntry.name)) ~ " M");
			}
		}
		return to!string(sort!("a.toLower() < b.toLower()")(app.data).join("\n").array());
	}

	const(Token)[] tokens;
	CompletionContext context;
}

unittest
{
	auto code = q{
struct TestStruct { int a; int b; }
TestStruct ts;
ts.a.
	};

	auto tokens = tokenize(code);
	auto mod = parseModule(tokens);
	auto context = new CompletionContext(mod);
	auto completion = AutoComplete(tokens, context);
	assert (completion.getTypeOfExpression(splitCallChain(tokens[13 .. 16]),
		tokens, 56) == "int");
}
