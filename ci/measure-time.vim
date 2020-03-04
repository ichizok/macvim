function s:estimate(n, t)
  let start = reltime()
  for _ in range(a:n)
    execute 'sleep' a:t
  endfor
  let elapsed = reltimefloat(reltime(start))
  let calibrator = (a:n * a:t * (a:t =~# 'm$' ? 1 : 1000)) / (elapsed * 1000)
  echo printf('%dx sleep %s', a:n, a:t)
  echo printf('Elapsed     = %f', elapsed)
  echo printf('Calibration = %f', calibrator)
  echo ''
endfunction

sleep 1

call s:estimate(1000, '1m')
call s:estimate(100, '10m')
call s:estimate(10, '100m')
call s:estimate(1, '1000m')
