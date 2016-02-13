require 'torch'
require 'nn'

local utils = require 'utils'


local layer, parent = torch.class('nn.SequenceLSTM', 'nn.Module')

--[[
If we add up the sizes of all the tensors for output, gradInput, weights,
gradWeights, and temporary buffers, we get that a SequenceLSTM stores this many
scalar values:

NTD + 6NTH + 8NH + 8H^2 + 8DH + 9H

For N = 100, D = 512, T = 100, H = 1024 and with 4 bytes per number, this comes
out to 305MB. Note that this class doesn't own input or gradOutput, so you'll
see a bit higher memory usage in practice.
--]]

function layer:__init(input_dim, hidden_dim)
  parent.__init(self)

  local D, H = input_dim, hidden_dim
  self.input_dim, self.hidden_dim = D, H

  self.weight = torch.Tensor(D + H, 4 * H)
  self.gradWeight = torch.Tensor(D + H, 4 * H):zero()
  self.bias = torch.Tensor(4 * H)
  self.gradBias = torch.Tensor(4 * H):zero()
  self:reset()

  self.cell = torch.Tensor()    -- This will be (N, T, H)
  self.gates = torch.Tensor()   -- This will be (N, T, 4H)
  self.buffer1 = torch.Tensor() -- This will be (N, H)
  self.buffer2 = torch.Tensor() -- This will be (N, H)
  self.buffer3 = torch.Tensor() -- This will be (H,)
  self.grad_a_buffer = torch.Tensor() -- This will be (N, 4H)

  self.gradInput = {torch.Tensor(), torch.Tensor(), torch.Tensor()}
end


function layer:reset(std)
  if not std then
    std = 1.0 / math.sqrt(self.hidden_dim + self.input_dim)
  end
  self.bias:zero()
  self.weight:normal(0, std)
  return self
end


function layer:_get_sizes(input, gradOutput)
  local h0, c0, x = unpack(input)
  local N, T = x:size(1), x:size(2)
  local H, D = self.hidden_dim, self.input_dim
  utils.check_dims(h0, {N, H})
  utils.check_dims(c0, {N, H})
  utils.check_dims(x, {N, T, D})
  return N, T, D, H
end


--[[
Input:
- h0: Initial hidden state, (N, H)
- c0: Initial cell state, (N, H)
- x: Input sequence, (N, T, D)

Output:
- h: Sequence of hidden states, (N, T, H)
--]]


function layer:updateOutput(input)
  local h0, c0, x = input[1], input[2], input[3]

  local N, T, D, H = self:_get_sizes(input)

  local bias_expand = self.bias:view(1, 4 * H):expand(N, 4 * H)
  local Wx = self.weight[{{1, D}}]
  local Wh = self.weight[{{D + 1, D + H}}]

  local h, c = self.output, self.cell
  h:resize(N, T, H):zero()
  c:resize(N, T, H):zero()
  local prev_h, prev_c = h0, c0
  self.gates:resize(N, T, 4 * H):zero()
  for t = 1, T do
    local cur_x = x[{{}, t}]
    local next_h = h[{{}, t}]
    local next_c = c[{{}, t}]
    local cur_gates = self.gates[{{}, t}]
    cur_gates:addmm(bias_expand, cur_x, Wx)
    cur_gates:addmm(prev_h, Wh)
    cur_gates[{{}, {1, 3 * H}}]:sigmoid()
    cur_gates[{{}, {3 * H + 1, 4 * H}}]:tanh()
    local i = cur_gates[{{}, {1, H}}]
    local f = cur_gates[{{}, {H + 1, 2 * H}}]
    local o = cur_gates[{{}, {2 * H + 1, 3 * H}}]
    local g = cur_gates[{{}, {3 * H + 1, 4 * H}}]
    next_h:cmul(i, g)
    next_c:cmul(f, prev_c):add(next_h)
    next_h:tanh(next_c):cmul(o)
    prev_h, prev_c = next_h, next_c
  end

  return self.output
end


function layer:backward(input, gradOutput, scale)
  scale = scale or 1.0
  local h0, c0, x = input[1], input[2], input[3]
  local grad_h0, grad_c0, grad_x = unpack(self.gradInput)
  local h, c = self.output, self.cell
  local grad_h = gradOutput

  local N, T, D, H = self:_get_sizes(input, gradOutput)
  local Wx = self.weight[{{1, D}}]
  local Wh = self.weight[{{D + 1, D + H}}]
  local grad_Wx = self.gradWeight[{{1, D}}]
  local grad_Wh = self.gradWeight[{{D + 1, D + H}}]
  local grad_b = self.gradBias

  grad_h0:resizeAs(h0):zero()
  grad_c0:resizeAs(c0):zero()
  grad_x:resizeAs(x):zero()
  local grad_next_h = self.buffer1:resizeAs(h0):zero()
  local grad_next_c = self.buffer2:resizeAs(c0):zero()
  for t = T, 1, -1 do
    local next_h, next_c = h[{{}, t}], c[{{}, t}]
    local prev_h, prev_c = nil, nil
    if t == 1 then
      prev_h, prev_c = h0, c0
    else
      prev_h, prev_c = h[{{}, t - 1}], c[{{}, t - 1}]
    end
    grad_next_h:add(grad_h[{{}, t}])

    local i = self.gates[{{}, t, {1, H}}]
    local f = self.gates[{{}, t, {H + 1, 2 * H}}]
    local o = self.gates[{{}, t, {2 * H + 1, 3 * H}}]
    local g = self.gates[{{}, t, {3 * H + 1, 4 * H}}]
    
    local grad_a = self.grad_a_buffer:resize(N, 4 * H):zero()
    local grad_ai = grad_a[{{}, {1, H}}]
    local grad_af = grad_a[{{}, {H + 1, 2 * H}}]
    local grad_ao = grad_a[{{}, {2 * H + 1, 3 * H}}]
    local grad_ag = grad_a[{{}, {3 * H + 1, 4 * H}}]
    
    -- We will use grad_ai, grad_af, and grad_ao as temporary buffers
    -- to to compute grad_next_c. We will need tanh_next_c (stored in grad_ai)
    -- to compute grad_ao; the other values can be overwritten after we compute
    -- grad_next_c
    local tanh_next_c = grad_ai:tanh(next_c)
    local tanh_next_c2 = grad_af:cmul(tanh_next_c, tanh_next_c)
    local my_grad_next_c = grad_ao
    my_grad_next_c:fill(1):add(-1, tanh_next_c2):cmul(o):cmul(grad_next_h)
    grad_next_c:add(my_grad_next_c)
    
    -- We need tanh_next_c (currently in grad_ai) to compute grad_ao; after
    -- that we can overwrite it.
    grad_ao:fill(1):add(-1, o):cmul(o):cmul(tanh_next_c):cmul(grad_next_h)

    -- Use grad_ai as a temporary buffer for computing grad_ag
    local g2 = grad_ai:cmul(g, g)
    grad_ag:fill(1):add(-1, g2):cmul(i):cmul(grad_next_c)

    -- We don't need any temporary storage for these so do them last
    grad_ai:fill(1):add(-1, i):cmul(i):cmul(g):cmul(grad_next_c)
    grad_af:fill(1):add(-1, f):cmul(f):cmul(prev_c):cmul(grad_next_c)
    
    grad_x[{{}, t}]:mm(grad_a, Wx:t())
    grad_Wx:addmm(scale, x[{{}, t}]:t(), grad_a)
    grad_Wh:addmm(scale, prev_h:t(), grad_a)
    local grad_a_sum = self.buffer3:resize(H):sum(grad_a, 1)
    grad_b:add(scale, grad_a_sum)

    grad_next_h:mm(grad_a, Wh:t())
    grad_next_c:cmul(f)
  end
  grad_h0:copy(grad_next_h)
  grad_c0:copy(grad_next_c)

  return self.gradInput
end

