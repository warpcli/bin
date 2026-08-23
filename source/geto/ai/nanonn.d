module geto.ai.nanonn;

import std.math : exp;

/// A single network layer.
interface Layer
{
    size_t inputs() const;
    size_t outputs() const;
    double[] weights();
    void setWeights(const double[] values);
    double[] forward(const double[] input);
    double[] backward(const double[] input, const double[] errors, double rate);
}

private double sigmoid(double x)
{
    return 1.0 / (1.0 + exp(-x));
}

private double dsigmoid(double x)
{
    return x * (1.0 - x);
}

/// A fully-connected layer with sigmoid activation.
final class Dense : Layer
{
    private double[] weightValues;
    private double[] outputValues;
    private double[] errorValues;

    this(size_t units, size_t inputCount)
    {
        weightValues = new double[units * (inputCount + 1)];
        outputValues = new double[units];
        errorValues = new double[inputCount];
    }

    size_t inputs() const
    {
        return errorValues.length;
    }

    size_t outputs() const
    {
        return outputValues.length;
    }

    double[] weights()
    {
        return weightValues;
    }

    void setWeights(const double[] values)
    {
        const count = values.length < weightValues.length ? values.length : weightValues.length;
        weightValues[0 .. count] = values[0 .. count];
    }

    double[] forward(const double[] input)
    {
        const stride = inputs + 1;
        foreach (i; 0 .. outputs)
        {
            double sum = 0;
            foreach (j; 0 .. inputs)
                sum += input[j] * weightValues[i * stride + j];
            outputValues[i] = sigmoid(sum + weightValues[i * stride + stride - 1]);
        }
        return outputValues;
    }

    double[] backward(const double[] input, const double[] errors, double rate)
    {
        const stride = inputs + 1;
        foreach (j; 0 .. inputs)
        {
            errorValues[j] = 0;
            foreach (i; 0 .. outputs)
                errorValues[j] += errors[i] * dsigmoid(outputValues[i]) * weightValues[i * stride
                + j];
        }
        foreach (i; 0 .. outputs)
        {
            const delta = rate * errors[i] * dsigmoid(outputValues[i]);
            foreach (j; 0 .. inputs)
                weightValues[i * stride + j] += delta * input[j];
            weightValues[i * stride + stride - 1] += delta;
        }
        return errorValues;
    }
}

/// Raised when adjacent layer shapes disagree.
class NetworkException : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// A sequence of layers trained by backpropagation.
final class Network
{
    private Layer[] layers;
    private const(double)[][] inputCache;
    private double[] errorBuffer;

    this(Layer[] sequence...)
    {
        import std.format : format;

        foreach (i, layer; sequence)
            if (i > 0 && layer.inputs != sequence[i - 1].outputs)
                throw new NetworkException(format("expected %d inputs, got %d",
                        layer.inputs, sequence[i - 1].outputs));
        layers = sequence.dup;
        inputCache = new const(double)[][](layers.length);
        errorBuffer = new double[layers[$ - 1].outputs];
    }

    /// Runs the input forward and returns the output layer's buffer.
    double[] predict(const double[] input)
    {
        double[] current = cast(double[]) input;
        foreach (layer; layers)
            current = layer.forward(current);
        return current;
    }

    /// Runs one backpropagation step, returning the mean squared error.
    double train(const double[] input, const double[] expected, double rate)
    {
        double[] current = cast(double[]) input;
        foreach (i, layer; layers)
        {
            inputCache[i] = current;
            current = layer.forward(current);
        }

        double total = 0;
        foreach (i; 0 .. expected.length)
        {
            errorBuffer[i] = expected[i] - current[i];
            total += errorBuffer[i] * errorBuffer[i];
        }

        double[] errors = errorBuffer;
        foreach_reverse (i; 0 .. layers.length)
            errors = layers[i].backward(inputCache[i], errors, rate);
        return total / expected.length;
    }
}

unittest
{
    // The classic XOR check: a 2-2-1 net should separate the classes.
    auto hidden = new Dense(4, 2);
    auto output = new Dense(1, 4);
    foreach (i, ref w; hidden.weights)
        w = (i % 7) * 0.19 - 0.6;
    foreach (i, ref w; output.weights)
        w = (i % 5) * 0.23 - 0.5;
    auto net = new Network(hidden, output);

    const double[2][4] samples = [[0, 0], [0, 1], [1, 0], [1, 1]];
    const double[4] targets = [0, 1, 1, 0];
    foreach (epoch; 0 .. 4000)
        foreach (i; 0 .. 4)
            net.train(samples[i][], [targets[i]], 0.5);

    foreach (i; 0 .. 4)
    {
        const predicted = net.predict(samples[i][])[0];
        assert((predicted > 0.5) == (targets[i] > 0.5));
    }
}
