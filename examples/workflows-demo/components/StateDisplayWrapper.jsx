import React from 'react'

// TODO: add remaining optional fields
const TaskState = ({
  id,
  Type,
  Resource,
  Parameters,
  Next
}) => {
  return (
    <div>
      <div><span className="uppercase text-xs">Name:</span> {id}</div>
      <div><span className="uppercase text-xs">Type:</span> {Type}</div>
      <div><span className="uppercase text-xs">Resource:</span> {Resource}</div>
      <div><span className="uppercase text-xs">Paremeters:</span> <div className="w-54 h-24 overflow-scroll">{JSON.stringify(Parameters)}</div></div>
      <div><span className="uppercase text-xs">Next:</span> {Next}</div>
    </div>
  )
}

// TODO: add remaining optional fields
const PassState = ({
  id,
  Type,
  Next
}) => {
  return (
    <div>
      <div><span className="uppercase text-xs">Name:</span> {id}</div>
      <div><span className="uppercase text-xs">Type:</span> {Type}</div>
      <div><span className="uppercase text-xs">Next:</span> {Next}</div>
    </div>
  )
}

const SucceedState = ({
  id,
  Type
}) => {
  return (
    <div>
      <div><span className="uppercase text-xs">Name:</span> {id}</div>
      <div><span className="uppercase text-xs">Type:</span> {Type}</div>
    </div>
  )
}

const flowStateMapping = {
  'Task': TaskState,
  'Pass': PassState,
  'Succeed': SucceedState
}

const StateDisplayWrapper = (props) => {
  const Component = flowStateMapping[props.Type]

  return <Component {...props} />
}

export { StateDisplayWrapper }
