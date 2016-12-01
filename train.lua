--[[----------------------------------------------------------------------------
Copyright (c) 2016-present, Facebook, Inc. All rights reserved.
This source code is licensed under the BSD-style license found in the
LICENSE file in the root directory of this source tree. An additional grant
of patent rights can be found in the PATENTS file in the same directory.

Train DeepMask or SharpMask
------------------------------------------------------------------------------]]

require 'torch'
require 'cutorch'
require 'cudnn'
--------------------------------------------------------------------------------
-- parse arguments
local cmd = torch.CmdLine()
cmd:text()
cmd:text('train DeepMask or SharpMask')
cmd:text()
cmd:text('Options:')
cmd:option('-rundir', 'exps/', 'experiments directory')
cmd:option('-name', '', 'name of experiment')
cmd:option('-datadir', 'data/', 'data directory')
cmd:option('-seed', 1, 'manually set RNG seed')
cmd:option('-gpu', 1, 'gpu device')
cmd:option('-nthreads', 4, 'number of threads for DataSampler')
cmd:option('-reload', '', 'reload a network from given directory')
cmd:text()
cmd:text('Training Options:')
cmd:option('-batch', 32, 'training batch size')
cmd:option('-lr', 0, 'learning rate (0 uses default lr schedule)')
cmd:option('-momentum', 0.9, 'momentum')
cmd:option('-wd', 5e-4, 'weight decay')
cmd:option('-maxload', 4000, 'max number of training batches per epoch')
cmd:option('-testmaxload', 500, 'max number of testing batches')
cmd:option('-maxepoch', 200, 'max number of training epochs')
cmd:option('-iSz', 160, 'input size')
cmd:option('-oSz', 56, 'output size')
cmd:option('-gSz', 112, 'ground truth size')
cmd:option('-scratch', false, 'train DeepMask with randomly initialize weights')
cmd:option('-verbose', true, 'output lots of info during training and testing')
cmd:text()
cmd:text('SharpMask Options:')
cmd:option('-dm', '', 'path to trained deepmask (if dm, then train SharpMask)')
cmd:option('-km', 32, 'km')
cmd:option('-ks', 32, 'ks')

local config = cmd:parse(arg)

--------------------------------------------------------------------------------
-- various initializations
torch.setdefaulttensortype('torch.FloatTensor')
cutorch.setDevice(config.gpu)
torch.manualSeed(config.seed)
math.randomseed(config.seed)

local trainSm -- flag to train SharpMask (true) or DeepMask (false)
if #config.dm > 0 then
  trainSm = true
  config.hfreq = 0 -- train only mask head
  config.gSz = config.iSz -- in sharpmask, ground-truth has same dim as input
end

paths.dofile('DeepCrop.lua')
if trainSm then paths.dofile('SharpMask.lua') end

--------------------------------------------------------------------------------
-- reload?
local epoch, model
if #config.reload > 0 then
  epoch = 0
  if paths.filep(config.reload..'/log') then
    for line in io.lines(config.reload..'/log') do
      if string.find(line,'train') then epoch = epoch + 1 end
    end
  end
  print(string.format('| reloading experiment %s', config.reload))
  local m = torch.load(string.format('%s/model.t7', config.reload))
  model, config = m.model, m.config
end

--------------------------------------------------------------------------------
-- directory to save log and model
local pathsv = trainSm and 'sharpmask/exp' or 'deepcrop/exp'
if #config.reload<1 then
	config.rundir = cmd:string(
	  paths.concat(config.rundir, pathsv),
	  config,{rundir=true, gpu=true, reload=true, datadir=true, dm=true} 
	)
end

print(string.format('| running in directory %s', config.rundir))
os.execute(string.format('mkdir -p %s',config.rundir))
os.execute(string.format('mkdir -p %s/samples/train',config.rundir))
os.execute(string.format('mkdir -p %s/samples/test',config.rundir))

--------------------------------------------------------------------------------
-- network and criterion
model = model or (trainSm and nn.SharpMask(config) or nn.DeepCrop(config))
local criterion = nn.SoftMarginCriterion():cuda()

print('| start training')

--------------------------------------------------------------------------------
-- initialize data loader
local DataLoader = paths.dofile('DataLoader.lua')
local trainLoader, valLoader = DataLoader.create(config)

--------------------------------------------------------------------------------
-- initialize Trainer (handles training/testing loop)
if trainSm then
  paths.dofile('TrainerSharpMask.lua')
else
  paths.dofile('TrainerDeepCrop.lua')
end
local trainer = Trainer(model, criterion, config)
--------------------------------------------------------------------------------
-- do it
local trainLossStr = '1'
local testLossStr = '1'
local trainErrorStr = '1'
local testErrorStr = '1'

epoch = epoch or 1
for i = 1, config.maxepoch do
  trainer:train(epoch,trainLoader)

  trainLossStr = string.format('%s,%f',trainLossStr,trainer.lossmeter:value())
  trainErrorStr = string.format('%s,%f',trainErrorStr,1-trainer.trainIouMeter:value('0.5'))
  print('| Train loss:')
  print(trainLossStr)
  print('| Train Error:')
  print(trainErrorStr)

  if i%2 == 0 then 
    trainer:test(epoch,valLoader) 

    testErrorStr = string.format('%s,%f',testErrorStr,1-trainer.testIouMeter:value('0.5'))
    print('| Test error:')
    print(testErrorStr)
  end

  epoch = epoch + 1
end
print('| training finished')
print('| Train loss:')
print(trainLossStr)
print('| Train Error:')
print(trainErrorStr)
print('| Test error:')
print(trainErrorStr)
