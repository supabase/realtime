import 'react-flow-renderer/dist/style.css'
import 'react-flow-renderer/dist/theme-default.css'
import React from 'react'
import ReactFlow, { Background, MiniMap, Controls } from 'react-flow-renderer'
import { getBezierPath, getMarkerEnd } from 'react-flow-renderer'
import { useState, useEffect } from 'react'
import { getWorkflow } from '../lib/api'

const elements = [
  { id: '1', type: 'input', data: { label: 'Node 1' }, position: { x: 250, y: 5 } },
  // you can also pass a React Node as a label
  { id: '2', data: { label: <div>Node 2</div> }, position: { x: 100, y: 100 } },
  { id: 'e1-2', source: '1', target: '2', animated: true },
]

const nodeWidth = 172
const nodeHeight = 36

export default function Flow({ id }) {
  const [workflow, setWorkflow] = useState(null)
  const [definition, setDefinition] = useState({})
  const [states, setWorkflowStates] = useState({})

  useEffect(() => {
    fetchWorkflow()
  }, [id])

  const fetchWorkflow = async () => {
    const { data, error } = await getWorkflow(id)
    console.log('data', data)

    if (data) {
      setWorkflow(data)
      setDefinition(data.definition)
      setWorkflowStates(data.definition.States)
    }
  }

  const renderFlows = () => {
    const spacing = 75
    const statesArray = Object.entries(states).map(([id, v]) => ({ id, ...v }))
      // Turn the states into an array
    let nodes = statesArray.map((x, i) => ({
      id: x.id,
      data: { label: <div>{x.id}</div> },
      position: { x: 400, y: i * spacing },
    }))

    let edges = statesArray
      .filter((x) => !!x.Next)
      .map((x, i) => ({
        id: `${x.id}-${x.Next}`,
        type: 'straight',
        source: x.id,
        target: x.Next,
        animated: true
      }))
      console.log('statesArray', statesArray)

        console.log('edges', edges)
    return [...nodes, ...edges]
  }

  if (!workflow) return <div></div>
  else
    return (
      <div className="flex w-full h-full">
        <div className="flex-grow">
          <div className="h-full">
            <ReactFlow elements={renderFlows()}>
              <Background variant="dots" />
              <Controls />
            </ReactFlow>
          </div>
        </div>

        <div className="w-64 p-4 border-l">
            <h4 className="uppercase text-xs text-gray-400 pb-4">Properties</h4>
            <h4 className="uppercase text-xs ">Name</h4>
          <h3>{workflow.name}</h3>
        </div>
      </div>
    )
}
