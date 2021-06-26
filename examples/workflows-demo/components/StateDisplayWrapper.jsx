import React, { useState } from 'react'

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

const EmailAction = ({
  id,
  Resource,
  Parameters,
  onSave
}) => {
  const [emailParams, setEmailParams] = useState({
    to: Parameters?.payload['to.$'] || Parameters?.payload['to'] || '',
    from: Parameters?.payload['from.$'] || Parameters?.payload['from'] || '',
    subject: Parameters?.payload['subject.$'] || Parameters?.payload['subject'] || '',
    text_body: Parameters?.payload['text_body.$'] || Parameters?.payload['text_body'] || ''
  })

  const onEmailParamsSave = () => {
    const params = {}

    for (const [key, value] of Object.entries(emailParams)) {
      params[value.startsWith('$.') ? `${key}.$` : key] = value
    }

    onSave(id, params)
  }

  return (
    <div className='flex flex-col'>
      <label>to:</label>
      <input
        className='border-2 rounded-sm border-gray-400'
        value={emailParams.to}
        onChange={(e) => setEmailParams(prop => ({ ...prop, to: e.target.value }))}
      />

      <label>from:</label>
      <input
        className='border-2 rounded-sm border-gray-400'
        value={emailParams.from}
        onChange={(e) => setEmailParams(prop => ({ ...prop, from: e.target.value }))}
      />

      <label>subject:</label>
      <input
        className='border-2 rounded-sm border-gray-400'
        value={emailParams.subject}
        onChange={(e) => setEmailParams(prop => ({ ...prop, subject: e.target.value }))}
      />

      <label>body:</label>
      <input
        className='border-2 rounded-sm border-gray-400'
        value={emailParams.text_body}
        onChange={(e) => setEmailParams(prop => ({ ...prop, text_body: e.target.value }))}
      />

      <button className="bg-white hover:bg-gray-100 text-gray-800 font-semibold py-2 px-4 border border-gray-400 rounded shadow" onClick={onEmailParamsSave}>
        Save
      </button>
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

const resourceMapping = {
  'email': EmailAction
}

const flowStateMapping = {
  'Task': TaskState,
  'Pass': PassState,
  'Succeed': SucceedState
}

const StateDisplayWrapper = (props) => {
  const Component = props.viewOnly ? flowStateMapping[props.Type] : (resourceMapping[props.Resource] || flowStateMapping[props.Type])

  return <Component {...props} />
}

export { StateDisplayWrapper }
