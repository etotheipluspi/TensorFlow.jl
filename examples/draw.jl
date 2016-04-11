# Simple implementation of http://arxiv.org/pdf/1502.04623v2.pdf in TensorFlow

# Example Usage:
# 	python draw.py --data_dir=/tmp/draw --read_attn=True --write_attn=True

# Author: Eric Jang
# (BM - from https://raw.githubusercontent.com/ericjang/draw/master/draw.py )

using TensorFlow
using TensorFlow.API
using TensorFlow.Train
using TensorFlow.InputData

import TensorFlow.API: LSTMCell, AdamOptimizer, DEFINE_string, DEFINE_boolean, clip_by_norm, sigmoid, get_variable, sigmoid
import TensorFlow: DT_FLOAT32

DEFINE_string("data_dir", "", "")
DEFINE_boolean("read_attn", true, "enable attention for reader")
DEFINE_boolean("write_attn", true, "enable attention for writer")

FLAGS[:_parse_flags]() # HACK clean up & export flags properly

## MODEL PARAMETERS ##

A, B          = (28,28) # image width,height
img_size      = B*A # the canvas size
enc_size      = 256 # number of hidden units / output size in LSTM
dec_size      = 256
read_n        = 5 # read glimpse grid width/height
write_n       = 5 # write glimpse grid width/height
read_size     = FLAGS[:read_attn] ? 2*read_n*read_n : 2img_size
write_size    = FLAGS[:write_attn] ? write_n*write_n : img_size
z_size        = 10 # QSampler output size
T             = 10 # MNIST generation sequence length
batch_size    = 100 # training minibatch size
train_iters   = 10000
learning_rate = 1e-3 # learning rate for optimizer
eps           = 1e-8 # epsilon for numerical stability

## BUILD MODEL ##

DO_SHARE      = false # "workaround for variable_scope(reuse=True)"

x = Placeholder(DT_FLOAT32, [batch_size, img_size]) # input (batch_size * img_size)
e = randn(Tensor, [batch_size, z_size]) # Qsampler noise
lstm_enc = LSTMCell(enc_size, read_size+dec_size) # encoder Op
lstm_dec = LSTMCell(dec_size, z_size) # decoder Op

"""
affine transformation Wx+b
assumes x.shape = (batch_size, num_features)
"""
function linear(x, output_dim)
  # TODO use get_variable instead?
  w = get_variable("w", [size(x, 2), output_dim])
  b = get_variable("b", [output_dim], initializer=constant_initializer(0.0))
  return x*w + b
end

function filterbank(gx, gy, sigma2, delta, N)
  grid_i = reshape(cast(1:N, DT_FLOAT32), [1, -1])
  mu_x   = gx + (grid_i - N / 2 - 0.5) * delta # eq 19
  mu_y   = gy + (grid_i - N / 2 - 0.5) * delta # eq 20
  a      = reshape(cast(1:A, DT_FLOAT32), [1, 1, -1])
  b      = reshape(cast(1:B, DT_FLOAT32), [1, 1, -1])
  mu_x   = reshape(mu_x, [-1, N, 1])
  mu_y   = reshape(mu_y, [-1, N, 1])
  sigma2 = reshape(sigma2, [-1, 1, 1])
  Fx     = exp(-((a - mu_x) / (2*sigma2))^2) # 2*sigma2?
  Fy     = exp(-((b - mu_y) / (2*sigma2))^2) # batch x N x B
  # normalize, sum over A and B dims
  Fx     = Fx / maximum(sum(Fx, 3), eps)
  Fy     = Fy / maximum(sum(Fy, 3), eps)
  return (Fx, Fy)
end

function attn_window(scope, h_dec, N)
  var_scope(scope, DO_SHARE) do s
    params = linear(h_dec, 5)
  end
  gx_, gy_, log_sigma2, log_delta, log_gamma = split(1,5,params) # TODO split (off by one?)
  gx = (A+1) / 2(gx_+1)
  gy = (B+1) / 2(gy_+1)
  sigma2 = exp(log_sigma2)
  delta = (max(A,B)-1)/(N-1) * exp(log_delta) # batch x N
  return tuple(filterbank(gx, gy, sigma2, delta, N)..., exp(log_gamma))
end

## READ ##
read_no_attn(x, x_hat, h_dec_prev) = hcat([x,x_hat])

function read_attn(x,x_hat,h_dec_prev)
  Fx, Fy, gamma = attn_window("read", h_dec_prev, read_n)
  function filter_img(img, Fx, Fy, gamma, N)
    Fxt = transpose(Fx, perm=[0,2,1])
    img = reshape(img, [-1,B,A])
    glimpse = batch_matmul(Fy, batch_matmul(img,Fxt))
    glimpse = reshape(glimpse, [-1,N*N])
    return glimpse * reshape(gamma,[-1,1])
  end
  x = filter_img(x, Fx, Fy, gamma, read_n) # batch x (read_n*read_n)
  x_hat = filter_img(x_hat, Fx, Fy, gamma, read_n)
  return hcat([x,x_hat]) # concat along feature axis
end
read = FLAGS[:read_attn] ? read_attn : read_no_attn

## ENCODE ##
"""
run LSTM
state = previous encoder state
input = cat(read,h_dec_prev)
returns: (output, new_state)
"""
function encode(state, input)
  var_scope("encoder", DO_SHARE) do s
    lstm_enc(input, state)
  end
end

## Q-SAMPLER (VARIATIONAL AUTOENCODER) ##

function sampleQ(h_enc)
  """
Samples Zt ~ normrnd(mu,sigma) via reparameterization trick for normal dist
  mu is (batch,z_size)
  """
  var_scope("mu", DO_SHARE) do s
    mu = linear(h_enc,z_size)
  end
  var_scope("sigma", DO_SHARE) do s
    logsigma = linear(h_enc,z_size)
    sigma = exp(logsigma)
  end
  return (mu + sigma*e, mu, logsigma, sigma)
end

## DECODER ##
function decode(state,input)
  var_scope("decoder", DO_SHARE) do s
    lstm_dec(input, state)
  end
end

## WRITER ##
function write_no_attn(h_dec)
  var_scope("write", DO_SHARE) do s
    linear(h_dec, img_size)
  end
end

function write_attn(h_dec)
  var_scope("writeW", DO_SHARE) do s
    w = linear(h_dec,write_size) # batch x (write_n*write_n)
  end
  N = write_n
  w = reshape(w, [batch_size,N,N])
  Fx, Fy, gamma = attn_window("write", h_dec, write_n)
  Fyt = transpose(Fy, perm=[0,2,1])
  wr = batch_matmul(Fyt, batch_matmul(w,Fx))
  wr = reshape(wr, [batch_size,B*A])
  #gamma = tf.tile(gamma,[1,B*A])
  return wr*reshape(1.0/gamma, [-1,1])
end

write = FLAGS[:write_attn] ? write_attn : write_no_attn

## STATE VARIABLES ##

cs = zeros(Float64, T) # sequence of canvases
# gaussian params generated by SampleQ. We will need these for computing loss.
mus, logsigmas, sigmas = (zeros(Float64, T), zeros(Float64, T), zeros(Float64, T))
# initial states
h_dec_prev = zeros(Tensor, [batch_size, dec_size])
enc_state = lstm_enc[:zero_state](batch_size, DT_FLOAT32)
dec_state = lstm_dec[:zero_state](batch_size, DT_FLOAT32)

## DRAW MODEL ##

# construct the unrolled computational graph
for t in 0:(T-1)
  c_prev = (t == 0) ? zeros(Tensor, [batch_size,img_size]) : cs[t-1]
  x_hat  = x - sigmoid(c_prev) # error image
  r      = read(x, x_hat, h_dec_prev)
  h_enc, enc_state = encode(enc_state, hcat([r,h_dec_prev]))

  z, mus[t], logsigmas[t], sigmas[t] = sampleQ(h_enc)
  h_dec, dec_state = decode(dec_state,z)
  cs[t] = c_prev + write(h_dec) # store results
  h_dec_prev = h_dec
  DO_SHARE = True # from now on, share variables
end

## LOSS FUNCTION ##

binary_crossentropy(t, o) = -(t*log(o + eps) + (1.0-t)*log(1.0 - o + eps))

# reconstruction term appears to have been collapsed down to a single scalar value (rather than one per item in minibatch)
x_recons = sigmoid(cs[-1])

# after computing binary cross entropy, sum across features then take the mean of those sums across minibatches
Lx = squeeze(sum(binary_crossentropy(x, x_recons), 2), 2) # reconstruction term
Lx = mean(Lx)

kl_terms = zeros(Float64, T)

for t in 0:(T-1)
  mu2 = mus[t]^2
  sigma2 = sigmas[t]^2
  logsigma = logsigmas[t]
  kl_terms[t] = 0.5sum(mu2 + sigma2 - 2logsigma, 2) - 0.5T # each kl term is (1xminibatch)
  KL = add_n(kl_terms) # this is 1xminibatch, corresponding to summing kl_terms from 1:T
  Lz = mean(KL) # average over minibatches
end

cost = Lx + Lz

## OPTIMIZER ##

optimizer = AdamOptimizer(learning_rate, beta1=0.5)
grads = optimizer.compute_gradients(cost)
for (i, (g,v)) in enumerate(grads)
  if g != nothing
    grads[i] = (clip_by_norm(g,5) ,v) # clip gradients
  end
end
train_op=optimizer.apply_gradients(grads)

## RUN TRAINING ##

data_directory = joinpath(FLAGS[:data_dir], "mnist")
if !ispath(data_directory)
  mkdir(data_directory)
end

train_data = mnist.input_data.read_data_sets(data_directory, one_hot=True).train # binarized (0-1) mnist data

fetches = []
append!(fetches, [Lx, Lz, train_op])
Lxs = zeros(train_iters)
Lzs = zeros(train_iters)


InteractiveSession() do sess
  saver = Saver() # saves variables learned during training
  run(sess, initialize_all_variables())
  #saver.restore(sess, "/tmp/draw/drawmodel.ckpt") # to restore from model, uncomment this line

  for i in 1:train_iters
    xtrain,_ = train_data.next_batch(batch_size) # xtrain is (batch_size x img_size)
    feed_dict = FeedDict(x => xtrain)
    results = run(sess, fetches, feed_dict)
    Lxs[i], Lzs[i], _ =results
    if i%100==0
      println("iter=%d : Lx: %f Lz: %f" % (i,Lxs[i],Lzs[i]))
    end
  end
  ## TRAINING FINISHED ##

  canvases = run(sess, cs, feed_dict) # generate some examples
  #canvases=np.array(canvases) # T x batch x img_size

  out_file = joinpath(FLAGS[:data_dir], "draw_data.jld")
  np.save(out_file,  [canvases,Lxs,Lzs])
  println("Outputs saved in file $out_file")

  ckpt_file = joinpath(FLAGS[:data_dir], "drawmodel.ckpt")
  println("Model saved in file: $(saver.save(sess, ckpt_file))")

end # do sess

println("Done drawing! Have a nice day! :)")
