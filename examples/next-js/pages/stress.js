import { RealtimeClient } from '@supabase/realtime-js'
import axios from 'axios'
const REALTIME_URL = process.env.REALTIME_URL || 'ws://localhost:4000/socket'
import { useEffect, useState, useRef } from 'react'
import Link from 'next/link'
import Chart from "chart.js";

const socket = new RealtimeClient(REALTIME_URL)
let timeChart;
let dataCountResponse = 0
let dateApiResponse = 0
let msgCounter = 0

export default function StressPage() {
  const chartRef = useRef(null)
  const countRef = useRef(null)
  const [status, setStatus] = useState('')

  const onClick = async () => {
    const val = Number(countRef.current?.value)
    msgCounter = 0
    setStatus('inserting rows to DB...')
    if (Number.isInteger(val) && val > 0) {
      insertToDb(val).then((res) => {
        dateApiResponse = Date.now()
        dataCountResponse = res.data.length
        setStatus('started measurement and waiting for a response from "realtime"...')
      })
    }
  }

  const updateChart = (count, time) => {
    timeChart.data.labels.push(count)
    timeChart.data.datasets[0].data.push((time / 1000).toFixed(2))
    timeChart.update()
  }

  const insertToDb = async (count) => {
    return await axios.post('/api/new-stress', {count})
  }

  useEffect(() => {
    socket.connect()
    const channel = socket.channel('realtime:*')
    let diff = 0
    channel.on('INSERT', msg => {
      if (++msgCounter == dataCountResponse) {
        diff = Date.now() - dateApiResponse
        updateChart(dataCountResponse, diff > 0 ? diff : 0)
        setStatus('completed')
      }
    })
    channel
      .subscribe()
      .receive('ok', () => console.log('Connecting'))
      .receive('error', () => console.log('Failed'))
      .receive('timeout', () => console.log('Waiting...'))

    timeChart = new Chart(chartRef.current.getContext("2d"), {
      type: "line",
      data: {
        labels: [],
        datasets: [{ label: "Seconds", data: [] }]
      },
      options: {
        scales: {
          yAxes: [{ ticks: { beginAtZero: true } }]
        }
      }
    })
    return () => {
      socket.disconnect()
      timeChart.destroy()
    };
  }, []);

  return (
    <div style={styles.main}>

      <Link href="/">index</Link> | <a>stress chart</a>

      <div style={styles.row}>
        <div style={styles.col}>
          <h3>How many rows to insert?</h3>
          <input type="number" min="1" defaultValue="100" ref={countRef} />
          <button onClick={onClick}>Execute</button> <span>{status}</span>
        </div>
      </div>

      <canvas className="code"
        id="myChart"
        ref={chartRef}
        style={styles.chart}
      />

    </div>
  )
}

const styles = {
  main: { fontFamily: 'monospace', height: '100%', margin: 0 },
  row: { display: 'flex', flexDirection: 'row', height: '100%', padding: 10 },
  chart: { width: '70%', maxWidth: '70%', padding: 10, height: '350', overflow: 'auto' },
}