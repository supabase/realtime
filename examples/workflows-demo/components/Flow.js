import 'react-flow-renderer/dist/style.css'
import 'react-flow-renderer/dist/theme-default.css'
import React from 'react'
import ReactFlow, { Background, MiniMap, Controls } from 'react-flow-renderer'
import { getBezierPath, getMarkerEnd } from 'react-flow-renderer'
import { useState, useEffect } from 'react'
import { getWorkflow } from '../lib/api'
import { StateDisplayWrapper } from './StateDisplayWrapper'

const elements = [
  { id: '1', type: 'input', data: { label: 'Node 1' }, position: { x: 250, y: 5 } },
  // you can also pass a React Node as a label
  { id: '2', data: { label: <div>Node 2</div> }, position: { x: 100, y: 100 } },
  { id: 'e1-2', source: '1', target: '2', animated: true },
]

const nodeWidth = 172
const nodeHeight = 36

export default function Flow({ id }) {
  const [workflow, setWorkflow] = useState()
  const [definition, setDefinition] = useState()
  const [states, setWorkflowStates] = useState()
  const [sortedNodes, setSortedNodes] = useState()
  const [elements, setElements] = useState()
  const [selectedStateMenu, setSelectedStateMenu] = useState()

  useEffect(() => {
    fetchWorkflow()
  }, [id])

  useEffect(() => {
    const startAt = definition?.StartAt

    startAt && states && setSortedNodes(getFlowElements(startAt))
  }, [definition, states])

  useEffect(() => {
    if (sortedNodes) {
      const elements = sortedNodes.reduce((acc, { id, Next }, i) => {
        acc.push({ 
          id,
          data: { label: <div>{id}</div> },
          position: { x: 400, y: (i + 1) * 100 },
        })

        Next && acc.push({
          id: `${id}-${Next}`,
          type: 'straight',
          source: id,
          target: Next,
          animated: true
        })

        return acc
      }, [])

      setElements(elements)
    }
  }, [sortedNodes])

  const fetchWorkflow = async () => {
    const { data, error } = await getWorkflow(id)
    console.log('data', data)

    if (data) {
      setWorkflow(data)
      setDefinition(data.definition)
      setWorkflowStates(data.definition.States)
    }
  }

  const getFlowElements = (nextNodeId, nodes=[], i=1) => {
    if (!nextNodeId) return nodes

    const node = states[nextNodeId]

    node && nodes.push({ id: nextNodeId, ...node })

    return getFlowElements(node?.Next, nodes, i + 1)
  }

  if (!workflow || !sortedNodes) return null

  return (
    <div className="flex w-full h-full">
      <div className="flex-grow">
        <div className="h-full">
          <ReactFlow
            elements={elements}
            onElementClick={(_, { id }) => setSelectedStateMenu(id)}
            onPaneClick={() => setSelectedStateMenu()}
          >
            <Background variant="dots" />
            <Controls />
          </ReactFlow>
        </div>
      </div>

      <div className="w-64 p-4 border-l">
        <h4 className="uppercase text-xs text-gray-400 pb-4">Properties</h4>
        <div className="m-1">
          <h4 className="uppercase text-xs underline">Name</h4>
          <h3>{workflow.name}</h3>
        </div>
        {selectedStateMenu ?
          <div className="m-1">
            <h4 className="uppercase text-xs underline">State</h4>
              <StateDisplayWrapper {...{ id: selectedStateMenu, ...states[selectedStateMenu] }} />
          </div> :
          <div className="m-1">
            <h4 className="uppercase text-xs underline">States</h4>
            <div className="divide-y">
              {sortedNodes.map(node => <StateDisplayWrapper key={node.id} {...node} />)}
            </div>
          </div>
        }
      </div>
    </div>
  )
}
