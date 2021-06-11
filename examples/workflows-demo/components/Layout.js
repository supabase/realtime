export default function Layout({ children }) {
  return (
    <div className="h-screen">
      <header className="border-b p-4"> Workflows | Executions </header>
      <div className="flex flex-row h-full"> {children}</div>
    </div>
  )
}
