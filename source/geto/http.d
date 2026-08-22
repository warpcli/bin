module geto.http;

import core.time : seconds;
import std.array : appender;
import std.conv : to;

import requests : Request;

import geto.log;
import geto.ui.progress : ProgressBar;

/// Raised for transport failures and non-2xx responses.
class HttpException : Exception
{
    ushort status;

    this(string message, ushort status = 0, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
        this.status = status;
    }
}

/// A completed HTTP response.
struct Response
{
    ushort status;
    ubyte[] content;

    string text() const
    {
        return cast(string) content.idup;
    }

    bool ok() const
    {
        return status >= 200 && status < 300;
    }
}

private Request newRequest(const string[string] headers)
{
    auto request = Request();
    request.timeout = 60.seconds;
    // Release assets routinely exceed the library's 5MB default.
    request.maxContentLength = 0;
    request.addHeaders(["User-Agent": "geto"]);
    if (headers.length > 0)
        request.addHeaders(cast(string[string]) headers);
    return request;
}

/// Performs a GET, returning the status and body without throwing on 4xx/5xx.
Response get(string url, const string[string] headers = null)
{
    auto request = newRequest(headers);
    try
    {
        auto response = request.get(url);
        return Response(response.code, cast(ubyte[]) response.responseBody.data.dup);
    }
    catch (Exception failure)
        throw new HttpException(failure.msg);
}

/// Performs a GET and throws unless the response is 2xx.
Response getOrThrow(string url, const string[string] headers = null)
{
    auto response = get(url, headers);
    if (!response.ok)
        throw new HttpException(response.status.to!string ~ " response from " ~ url,
                response.status);
    return response;
}

/// Streams a URL into memory, drawing a progress bar unless `quiet`.
ubyte[] download(string url, const string[string] headers, string label, bool quiet)
{
    auto request = newRequest(headers);
    request.useStreaming = true;

    debugf("Checking binary from %s", url);
    try
    {
        auto response = request.get(url);
        if (response.code < 200 || response.code > 299)
            throw new HttpException(response.code.to!string
                    ~ " response when checking binary from " ~ url, response.code);

        auto bar = ProgressBar(response.contentLength, label);
        scope (exit)
            if (!quiet)
                bar.finish();

        auto output = appender!(ubyte[]);
        auto stream = response.receiveAsRange();
        while (!stream.empty)
        {
            output ~= stream.front;
            if (!quiet)
                bar.advance(stream.front.length);
            stream.popFront();
        }
        return output.data;
    }
    catch (HttpException failure)
        throw failure;
    catch (Exception failure)
        throw new HttpException(failure.msg);
}
