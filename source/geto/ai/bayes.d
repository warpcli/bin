module geto.ai.bayes;

import std.algorithm : maxElement;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON, toJSON;
import std.math : exp, isNaN, log;

/// The tiny non-zero probability used when a class has no training data.
private enum double defaultProb = 1e-11;

private struct ClassData
{
    double[string] freqs;
    long total;
}

/// A multinomial naive Bayes classifier with Laplace smoothing.
final class Classifier
{
    string[] classes;
    private ClassData[string] datas;
    private long learnedCount;
    private long seenCount;

    this(string[] names...)
    {
        classes = names.dup;
        foreach (name; classes)
            datas[name] = ClassData.init;
    }

    /// Number of documents ever learned.
    long learned() const
    {
        return learnedCount;
    }

    /// Number of documents ever classified.
    long seen() const
    {
        return seenCount;
    }

    /// Records a training document against one class.
    void learn(const string[] document, string which)
    {
        auto data = which in datas;
        if (data is null)
            return;
        foreach (word; document)
        {
            data.freqs[word] = data.freqs.get(word, 0.0) + 1.0;
            data.total++;
        }
        learnedCount++;
    }

    /// P(W|C) under add-one smoothing.
    private double wordProb(const ref ClassData data, string word) const
    {
        const vocab = data.freqs.length;
        if (data.total == 0 || vocab == 0)
            return defaultProb;
        const value = data.freqs.get(word, 0.0);
        return (value + 1.0) / (cast(double) data.total + cast(double) vocab);
    }

    /// Class priors under add-one smoothing.
    private double[] priors() const
    {
        auto result = new double[classes.length];
        long sum = 0;
        foreach (i, name; classes)
        {
            const total = (name in datas).total;
            result[i] = cast(double) total;
            sum += total;
        }
        foreach (i; 0 .. result.length)
            result[i] = (result[i] + 1.0) / (cast(double) sum + cast(double) classes.length);
        return result;
    }

    /// Normalized per-class probabilities, falling back to the log domain on
    /// underflow so the ordering stays meaningful for long documents.
    double[] probScores(const string[] document)
    {
        const n = classes.length;
        auto scores = new double[n];
        auto logScores = new double[n];
        const prior = priors();
        double sum = 0;

        foreach (i, name; classes)
        {
            const data = name in datas;
            double score = prior[i];
            double logScore = log(prior[i]);
            foreach (word; document)
            {
                const p = wordProb(*data, word);
                score *= p;
                logScore += log(p);
            }
            scores[i] = score;
            logScores[i] = logScore;
            sum += score;
        }

        seenCount++;

        if (sum == 0)
            return logScoresToProbs(logScores);

        foreach (i; 0 .. n)
            scores[i] /= sum;

        // Disagreement between the two domains means partial underflow.
        if (indexOfMax(scores) != indexOfMax(logScores))
            return logScoresToProbs(logScores);
        return scores;
    }

    private static size_t indexOfMax(const double[] values)
    {
        size_t best = 0;
        foreach (i; 1 .. values.length)
            if (values[i] > values[best])
                best = i;
        return best;
    }

    private static double[] logScoresToProbs(const double[] logScores)
    {
        auto probs = new double[logScores.length];
        double maxLog = logScores[0];
        foreach (value; logScores[1 .. $])
            if (value > maxLog)
                maxLog = value;

        double sum = 0;
        foreach (i, value; logScores)
        {
            probs[i] = exp(value - maxLog);
            sum += probs[i];
        }
        foreach (i; 0 .. probs.length)
            probs[i] /= sum;
        return probs;
    }

    /// Serializes the model. Replaces the Go build's gob encoding.
    string toJson() const
    {
        JSONValue[string] classData;
        foreach (name, data; datas)
        {
            JSONValue[string] freqs;
            foreach (word, count; data.freqs)
                freqs[word] = count;
            JSONValue[string] node;
            node["freqs"] = JSONValue(freqs);
            node["total"] = data.total;
            classData[name] = JSONValue(node);
        }
        JSONValue[string] root;
        root["classes"] = JSONValue(classes.dup);
        root["learned"] = learnedCount;
        root["seen"] = seenCount;
        root["datas"] = JSONValue(classData);
        auto node = JSONValue(root);
        return toJSON(node, false, JSONOptions.doNotEscapeSlashes);
    }

    /// Restores a model written by `toJson`. Throws on malformed input.
    static Classifier fromJson(string text)
    {
        auto root = parseJSON(text);
        if (root.type != JSONType.object)
            throw new Exception("classifier model is not an object");

        string[] names;
        if (auto found = "classes" in root.objectNoRef)
            foreach (item; found.arrayNoRef)
                names ~= item.str;
        if (names.length < 2)
            throw new Exception("classifier model needs at least two classes");

        auto result = new Classifier(names);
        if (auto found = "learned" in root.objectNoRef)
            result.learnedCount = found.integer;
        if (auto found = "seen" in root.objectNoRef)
            result.seenCount = found.integer;

        if (auto found = "datas" in root.objectNoRef)
            foreach (name, node; found.objectNoRef)
            {
                if (name !in result.datas)
                    continue;
                ClassData data;
                if (auto totalNode = "total" in node.objectNoRef)
                    data.total = totalNode.integer;
                if (auto freqNode = "freqs" in node.objectNoRef)
                    foreach (word, countNode; freqNode.objectNoRef)
                        data.freqs[word] = countNode.type == JSONType.integer
                            ? cast(double) countNode.integer : countNode.floating;
                result.datas[name] = data;
            }
        return result;
    }
}

unittest
{
    auto classifier = new Classifier("Match", "Mismatch");
    classifier.learn(["linux", "musl", "amd64"], "Match");
    classifier.learn(["linux", "gnu", "amd64"], "Match");
    classifier.learn(["windows", "msvc"], "Mismatch");
    classifier.learn(["darwin", "universal"], "Mismatch");
    assert(classifier.learned == 4);

    const matchScore = classifier.probScores(["linux", "musl"])[0];
    const mismatchScore = classifier.probScores(["windows", "msvc"])[0];
    assert(matchScore > mismatchScore);

    auto restored = Classifier.fromJson(classifier.toJson());
    assert(restored.learned == classifier.learned);
    assert(restored.probScores(["linux", "musl"])[0] == matchScore);
}
