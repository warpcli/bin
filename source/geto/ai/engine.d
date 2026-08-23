module geto.ai.engine;

import std.algorithm : canFind, endsWith, startsWith;
import std.array : array;
import std.ascii : isAlphaNum, isDigit, isHexDigit;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, remove, rename, write;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON, toJSON;
import std.math : isFinite, isNaN, sqrt;
import std.path : buildPath;
import std.random : Mt19937, uniform01;
import std.string : toLower;

import geto.ai.bayes : Classifier;
import geto.ai.nanonn : Dense, Network;

enum matchClass = "Match";
enum mismatchClass = "Mismatch";

/// Feature vector schema version. Bumped from the Go build's 2 because the
/// classifier is now stored as JSON rather than Go's gob encoding.
private enum int modelVersion = 3;

private enum classifierFile = "bayesian.json";
private enum stateFile = "model.json";

private enum size_t numHidden = 8;
private enum double learningRate = 0.1;
private enum size_t trainEpochs = 5;
private enum uint initSeed = 0x62696e41;

// Gate thresholds for automatic tie-breaking.
private enum size_t minSelections = 5;
private enum double minTopScore = 0.60;
private enum double minMargin = 0.20;

// Feature indices for candidate scoring.
private enum
{
    fBayes = 0,
    fMusl,
    fGnu,
    fStatic,
    fRepoRank,
    fVariant,
    fTarball,
    fZip,
    fExotic,
    numFeatures,
}

/// Ranks release-asset candidates using naive Bayes plus a small neural net.
final class Engine
{
    private Classifier classifier;
    private Network net;
    private Dense layer1;
    private Dense layer2;
    private long selectionCount;
    private bool seededFlag;

    private this()
    {
        layer1 = new Dense(numHidden, numFeatures);
        layer2 = new Dense(1, numHidden);

        auto rng = Mt19937(initSeed);
        seedWeights(rng, layer1, numFeatures, numHidden);
        seedWeights(rng, layer2, numHidden, 1);

        net = new Network(layer1, layer2);
        classifier = new Classifier(matchClass, mismatchClass);
    }

    /// An untrained engine with deterministic initial weights.
    static Engine untrained()
    {
        return new Engine;
    }

    /// An engine preloaded with the embedded seed model.
    static Engine create()
    {
        auto engine = new Engine;
        engine.loadSeed();
        return engine;
    }

    /// Xavier/Glorot uniform initialisation, which suits sigmoid activations.
    private static void seedWeights(ref Mt19937 rng, Dense layer, size_t fanIn, size_t fanOut)
    {
        const limit = sqrt(6.0 / cast(double)(fanIn + fanOut));
        auto values = new double[layer.weights.length];
        foreach (ref value; values)
            value = (uniform01!double(rng) * 2 - 1) * limit;
        layer.setWeights(values);
    }

    long selections() const
    {
        return selectionCount;
    }

    bool seeded() const
    {
        return seededFlag;
    }

    /// Whether the engine has enough history to be worth consulting.
    bool trained() const
    {
        return seededFlag || selectionCount >= minSelections;
    }

    /// Confidence in [0,1] that `filename` is the wanted asset. Only the
    /// ordering between candidates from one release is meaningful.
    double score(string filename, string repoName)
    {
        auto output = net.predict(features(filename, repoName));
        if (output.length == 0)
            return 0;
        const value = output[0];
        // A diverged net reports no opinion rather than slipping past the gate.
        if (value.isNaN)
            return 0;
        if (value < 0)
            return 0;
        if (value > 1)
            return 1;
        return value;
    }

    /// Picks a winner among candidates the deterministic scorer rated equally.
    /// Reports false on ties or when the leader is not clearly ahead.
    bool decide(const string[] names, string repoName, out string best)
    {
        if (names.length == 0)
            return false;
        if (names.length == 1)
        {
            best = names[0];
            return true;
        }
        if (!trained)
            return false;

        double top = -double.infinity;
        double second = -double.infinity;
        foreach (name; names)
        {
            const value = score(name, repoName);
            if (value > top)
            {
                second = top;
                top = value;
                best = name;
            }
            else if (value > second)
                second = value;
        }
        if (top < minTopScore || top - second < minMargin)
        {
            best = "";
            return false;
        }
        return true;
    }

    /// Records a user selection and trains on it.
    void observe(string chosen, const string[] rejected, string repoName)
    {
        learn(chosen, rejected, repoName);
        selectionCount++;
    }

    /// Records rejections without a winner.
    void observeRejections(const string[] rejected, string repoName)
    {
        learn("", rejected, repoName);
    }

    private void learn(string chosen, const string[] rejected, string repoName)
    {
        if (rejected.length == 0)
        {
            if (chosen.length > 0)
            {
                classifier.learn(tokenize(chosen), matchClass);
                foreach (_; 0 .. trainEpochs)
                    net.train(features(chosen, repoName), [1.0], learningRate);
            }
            return;
        }

        foreach (name; rejected)
        {
            if (chosen.length > 0)
                classifier.learn(tokenize(chosen), matchClass);
            classifier.learn(tokenize(name), mismatchClass);
        }

        foreach (_; 0 .. trainEpochs)
            foreach (name; rejected)
            {
                if (chosen.length > 0)
                    net.train(features(chosen, repoName), [1.0], learningRate);
                net.train(features(name, repoName), [0.0], learningRate);
            }
    }

    // -----------------------------------------------------------------------
    // Persistence
    // -----------------------------------------------------------------------

    /// Writes the model files atomically.
    void save(string dir)
    {
        if (dir.length == 0)
            throw new Exception("no model directory");
        mkdirRecurse(dir);

        if (!allFinite(layer1.weights) || !allFinite(layer2.weights))
            throw new Exception("refusing to save non-finite weights");

        JSONValue[string] state;
        state["version"] = modelVersion;
        state["selections"] = selectionCount;
        state["seeded"] = seededFlag;
        state["weights1"] = JSONValue(layer1.weights.dup);
        state["weights2"] = JSONValue(layer2.weights.dup);

        writeFileAtomic(buildPath(dir, classifierFile), classifier.toJson());
        auto stateNode = JSONValue(state);
        writeFileAtomic(buildPath(dir, stateFile),
            toJSON(stateNode, false, JSONOptions.doNotEscapeSlashes));
    }

    /// Restores model state, throwing when it is absent or unusable.
    void load(string dir)
    {
        if (dir.length == 0)
            throw new Exception("no model directory");

        auto root = parseJSON(readText(buildPath(dir, stateFile)));
        if (root.type != JSONType.object)
            throw new Exception("model state is not an object");

        const version_ = ("version" in root.objectNoRef) ? root["version"].integer : 0;
        if (version_ != modelVersion)
            throw new Exception("model version " ~ version_.to!string
                    ~ ", want " ~ modelVersion.to!string);

        auto weights1 = readWeights(root, "weights1");
        auto weights2 = readWeights(root, "weights2");
        if (weights1.length != layer1.weights.length)
            throw new Exception("hidden layer has " ~ weights1.length.to!string
                    ~ " weights, want " ~ layer1.weights.length.to!string);
        if (weights2.length != layer2.weights.length)
            throw new Exception("output layer has " ~ weights2.length.to!string
                    ~ " weights, want " ~ layer2.weights.length.to!string);
        if (!allFinite(weights1) || !allFinite(weights2))
            throw new Exception("model contains non-finite weights");

        const count = ("selections" in root.objectNoRef) ? root["selections"].integer : 0;
        if (count < 0)
            throw new Exception("model reports " ~ count.to!string ~ " selections");

        auto restored = Classifier.fromJson(readText(buildPath(dir, classifierFile)));

        classifier = restored;
        layer1.setWeights(weights1);
        layer2.setWeights(weights2);
        selectionCount = count;
        seededFlag = ("seeded" in root.objectNoRef) && root["seeded"].type == JSONType.true_;
    }

    private void loadSeed()
    {
        enum seedState = import("model.json");
        enum seedClassifier = import("bayesian.json");

        try
        {
            auto root = parseJSON(seedState);
            // The embedded seed predates the JSON classifier, so its recorded
            // version is the Go build's; only the shape has to line up.
            auto weights1 = readWeights(root, "weights1");
            auto weights2 = readWeights(root, "weights2");
            if (weights1.length != layer1.weights.length
                || weights2.length != layer2.weights.length)
                return;
            if (!allFinite(weights1) || !allFinite(weights2))
                return;

            classifier = Classifier.fromJson(seedClassifier);
            layer1.setWeights(weights1);
            layer2.setWeights(weights2);
            seededFlag = true;
        }
        catch (Exception)
        {
        }
    }

    private static double[] readWeights(const JSONValue root, string key)
    {
        double[] result;
        if (root.type != JSONType.object)
            return result;
        auto found = key in root.objectNoRef;
        if (found is null || found.type != JSONType.array)
            return result;
        foreach (item; found.arrayNoRef)
            result ~= item.type == JSONType.integer
                ? cast(double) item.integer : item.floating;
        return result;
    }

    // -----------------------------------------------------------------------
    // Features
    // -----------------------------------------------------------------------

    private double[] features(string filename, string repoName)
    {
        const lower = filename.toLower;
        bool tarball, zip, exotic;
        archiveKind(lower, tarball, zip, exotic);

        auto result = new double[numFeatures];
        result[fBayes] = textScore(tokenize(filename));
        result[fMusl] = lower.canFind("musl") ? 1.0 : 0.0;
        result[fGnu] = (lower.canFind("gnu") || lower.canFind("glibc")) ? 1.0 : 0.0;
        result[fStatic] = hasToken(lower, ["static"]) ? 1.0 : 0.0;
        result[fRepoRank] = repoNameRank(lower, repoName);
        result[fVariant] = hasToken(lower, variantTokens) ? 1.0 : 0.0;
        result[fTarball] = tarball ? 1.0 : 0.0;
        result[fZip] = zip ? 1.0 : 0.0;
        result[fExotic] = exotic ? 1.0 : 0.0;
        return result;
    }

    private double textScore(const string[] tokens)
    {
        if (tokens.length == 0 || classifier.learned == 0)
            return 0.5;
        auto scores = classifier.probScores(tokens);
        return scores.length == 0 ? 0.5 : scores[0];
    }
}

/// Removes persisted model files, reporting whether anything was deleted.
bool resetModel(string dir)
{
    if (dir.length == 0)
        throw new Exception("no model directory");
    bool removed = false;
    foreach (name; [classifierFile, stateFile])
    {
        const path = buildPath(dir, name);
        if (!path.exists)
            continue;
        remove(path);
        removed = true;
    }
    return removed;
}

// ---------------------------------------------------------------------------
// Tokenisation and heuristics
// ---------------------------------------------------------------------------

private immutable string[] variantTokens = [
    "debug", "dbg", "symbols", "syms", "profile", "baseline",
    "src", "source", "sources", "vendor", "sbom", "package", "npm",
    "installer", "setup", "gui", "desktop", "app", "ui",
    "android", "ios", "cuda", "rocm", "vulkan", "mlx", "jetpack",
    "jetpack5", "jetpack6", "fips",
];

private immutable bool[string] platformTokens;

shared static this()
{
    bool[string] tokens;
    foreach (name; [
            "linux", "windows", "win", "win32", "win64", "freebsd", "netbsd",
            "openbsd", "dragonfly", "solaris", "illumos", "android", "amd64",
            "x86", "x64", "i386", "i686", "i586", "arm", "arm64", "aarch64",
            "armv6", "armv7", "armv8", "armhf", "armel", "ppc64", "ppc64le",
            "s390x", "mips", "mipsle", "mips64", "mips64le", "riscv64",
            "loong64", "universal", "universal2", "intel", "intel64",
            "powerpc", "gnu", "gnueabi", "gnueabihf", "musl", "musleabi",
            "musleabihf", "msvc", "mingw", "mingw32", "mingw64", "unknown",
            "pc", "none", "static", "tar", "gz", "tgz", "zip", "bz2", "tbz",
            "tbz2", "xz", "txz", "zst", "tzst", "7z", "exe", "appimage",
            "deb", "rpm", "dmg", "pkg", "msi", "bin"
        ])
        tokens[name] = true;
    platformTokens = cast(immutable) tokens;
}

/// Alphanumeric tokens of a lowercased name.
string[] splitTokens(string name)
{
    string[] result;
    string current;
    foreach (dchar c; name.toLower)
    {
        if (c < 128 && (cast(char) c).isAlphaNum)
            current ~= cast(char) c;
        else
        {
            if (current.length > 0)
                result ~= current;
            current = null;
        }
    }
    if (current.length > 0)
        result ~= current;
    return result;
}

private bool isNumericToken(string token)
{
    auto rest = token;
    if (rest.startsWith("v"))
        rest = rest[1 .. $];
    if (rest.length == 0)
        return false;
    foreach (c; rest)
        if (!c.isDigit)
            return false;
    return true;
}

private bool isHashToken(string token)
{
    if (token.length < 7)
        return false;
    foreach (c; token)
        if (!(c.isDigit || (c >= 'a' && c <= 'f')))
            return false;
    return true;
}

/// Normalized vocabulary tokens, dropping versions, hashes, and outliers.
string[] tokenize(string name)
{
    string[] result;
    foreach (token; splitTokens(name))
    {
        if (token.length < 2 || token.length > 32)
            continue;
        if (isNumericToken(token) || isHashToken(token))
            continue;
        result ~= token;
    }
    return result;
}

private bool hasToken(string name, const string[] wanted)
{
    foreach (token; splitTokens(name))
        if (wanted.canFind(token))
            return true;
    return false;
}

/// Ranks how closely a filename matches the repository name.
private double repoNameRank(string lower, string repoName)
{
    if (repoName.length == 0)
        return 0;
    auto repoParts = splitTokens(repoName);
    if (repoParts.length == 0)
        return 0;

    auto parts = splitTokens(lower);
    if (parts.length > repoParts.length && parts[0 .. repoParts.length] == repoParts)
    {
        const next = parts[repoParts.length];
        if ((next in platformTokens) !is null || isNumericToken(next))
            return 1.0;
    }
    if (lower.canFind(repoName.toLower))
        return 0.5;
    return 0;
}

private void archiveKind(string lower, out bool tarball, out bool zip, out bool exotic)
{
    static bool hasAnySuffix(string text, const string[] suffixes)
    {
        foreach (suffix; suffixes)
            if (text.endsWith(suffix))
                return true;
        return false;
    }

    if (hasAnySuffix(lower, [".tar.gz", ".tgz", ".tar"]))
        tarball = true;
    else if (lower.endsWith(".zip"))
        zip = true;
    else if (hasAnySuffix(lower, [
            ".tar.bz2", ".tbz2", ".tbz", ".bz2", ".tar.xz", ".txz", ".xz",
            ".tar.zst", ".tzst", ".zst", ".7z"
        ]))
        exotic = true;
}

private bool allFinite(const double[] values)
{
    foreach (value; values)
        if (!value.isFinite)
            return false;
    return true;
}

private void writeFileAtomic(string path, string data)
{
    import std.conv : octal;
    import std.file : setAttributes;

    const temp = path ~ ".tmp";
    write(temp, data);
    setAttributes(temp, octal!"644");
    rename(temp, path);
}

unittest
{
    assert(tokenize("ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz")
            == ["ripgrep", "x86", "unknown", "linux", "musl", "tar", "gz"]);
    assert(splitTokens("Foo_Bar-1.2") == ["foo", "bar", "1", "2"]);
    assert(isNumericToken("v12") && !isNumericToken("v12a"));
    assert(isHashToken("deadbeef") && !isHashToken("dead"));

    bool tarball, zip, exotic;
    archiveKind("tool.tar.gz", tarball, zip, exotic);
    assert(tarball && !zip && !exotic);
    archiveKind("tool.zip", tarball, zip, exotic);
    assert(zip);

    auto engine = Engine.create();
    assert(engine.seeded);
    assert(engine.trained);
    // The seed corpus prefers a musl Linux build over a Windows one.
    assert(engine.score("tool-x86_64-unknown-linux-musl.tar.gz", "tool")
            > engine.score("tool-x86_64-pc-windows-msvc.zip", "tool"));
}
